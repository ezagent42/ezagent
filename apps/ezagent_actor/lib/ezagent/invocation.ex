defmodule Ezagent.Invocation do
  @moduledoc """
  Invocation — the universal request shape.

  Per ARCHITECTURE.md §4.2 + Appendix A. Adapters construct
  `%Ezagent.Invocation{}` from external protocol events, then call
  `dispatch/1`; the dispatch path is shared regardless of adapter.

  ## 12-step dispatch flow (Appendix A)

  Phase 1 implementation splits the 12 steps between this module
  (steps 1-4, 11-12) and `Ezagent.Kind.Runtime` (steps 5-10, inside the
  Kind GenServer). Validation (step 2.5) moves to step 5.5 because
  it needs the Behavior's `@interface` which is found in step 5.

  Phase 9 PR-4 (SPEC v3 §5) added step 5.6 — workspace isolation —
  inside `Kind.Runtime` adjacent to step 5.5. Cross-workspace
  dispatch now returns `{:error, :cross_workspace_denied}` instead
  of silently succeeding when a cap matches structurally but the
  caller's workspace differs from the target's.

  ## Reply table

  `reply/2` routes a result back to the caller per `ctx.reply` (7
  cases per §4.3). Phase 1 implements `:caller_inbox`, `:phoenix_pubsub`,
  `:ignore` — the protocol-bound cases (`:plug_conn`, `:phoenix_channel`,
  `:stdio_pipe`, `:mcp_response`) raise on use until their adapter
  arrives in later phases.
  """

  require Logger

  # Cold-activation budget for a synchronous (`:call`/`:call_stream`) dispatch
  # landing on a target whose Kind is still running `activate/2` (post_init).
  # Bumped from 5s because COLD HEAVY FLAVORS routinely need >5s to become
  # ready: a cc agent launches the `claude` CLI AND its PtyServer auto-prompts
  # scanner clicks through claude's startup dialogs before the Kind announces
  # `:ready` — observed at ~5-20s. The old 5s budget turned a legitimate cold
  # activation into a spurious `:error, :activate_timeout` (FP5 S5 #115). This
  # is the RESIDUAL budget for dispatches that legitimately must reach a cold
  # agent (chat sends, etc.) — config/caps READ surfaces no longer activate at
  # all (`Ezagent.Agent.Config.read_cascade/4` + `Ezagent.World.IdentityData`
  # now snapshot-read), so this budget only covers genuine cold work. The
  # `{:error, :timeout} -> {:error, :activate_timeout}` distinct signal is
  # preserved so a GENUINELY stuck `activate` still surfaces (let-it-crash).
  # Overridable via `config :ezagent_core, :activate_budget_ms` (tests set it low
  # to exercise the timeout path without blocking 20s) — see `activate_budget_ms/0`.
  @default_activate_budget_ms 20_000
  @admin_operator_scope_key {__MODULE__, :admin_operator_presenter}

  @doc """
  Cold-activation budget (ms) for a synchronous dispatch awaiting a target's
  `activate/2`. Defaults to #{@default_activate_budget_ms}ms; override with
  `config :ezagent_core, :activate_budget_ms`. See the `@default_activate_budget_ms`
  comment for WHY heavy flavors (cc) legitimately need >5s.
  """
  @spec activate_budget_ms() :: pos_integer()
  def activate_budget_ms do
    Application.get_env(:ezagent_core, :activate_budget_ms, @default_activate_budget_ms)
  end

  @type mode :: :call | :cast | :call_stream | :subscribe | :introspect

  @type reply_target ::
          {:phoenix_channel, topic :: String.t()}
          | {:phoenix_pubsub, topic :: String.t()}
          | {:plug_conn, conn :: term()}
          | {:stdio_pipe, pid :: port()}
          | {:mcp_response, request_id :: String.t()}
          | {:caller_inbox, pid :: pid()}
          | :ignore

  @type ctx :: %{
          required(:caller) => URI.t(),
          required(:caps) => MapSet.t(term()),
          required(:reply) => reply_target(),
          optional(:authenticated_principal) => URI.t(),
          optional(:trace_id) => String.t(),
          optional(:deadline_ms) => pos_integer(),
          optional(:idempotency_key) => String.t()
        }

  @enforce_keys [:target, :mode, :args, :ctx]
  defstruct [:target, :mode, :args, :ctx, origin: nil]

  @type t :: %__MODULE__{
          target: URI.t(),
          mode: mode(),
          args: map(),
          ctx: ctx(),
          origin: term()
        }

  # --- dispatch ----------------------------------------------------------

  @doc """
  Run reviewed framework operator code with permission to obtain exact
  target-signed action caps through `K.grant`.

  The scope is process-local, presenter-bound, and always restored. Ordinary
  `dispatch/1` callers do not enter it; an empty capability envelope therefore
  remains a fail-loud denial outside the explicit CLI/World/Session-Config
  adapters. Malicious code already executing in the BEAM is outside Path A.
  """
  @spec with_admin_operator(URI.t(), (-> result)) :: result when result: term()
  def with_admin_operator(%URI{} = presenter, fun) when is_function(fun, 0) do
    previous = Process.get(@admin_operator_scope_key, :unset)
    Process.put(@admin_operator_scope_key, Ezagent.URI.stable_key(presenter))

    try do
      fun.()
    after
      case previous do
        :unset -> Process.delete(@admin_operator_scope_key)
        value -> Process.put(@admin_operator_scope_key, value)
      end
    end
  end

  @doc """
  Dispatch this invocation. See Appendix A for the 12-step flow.

  Phase 1 simplifications:
  - Args validation (step 2.5) is deferred into the Kind.Runtime path
    after BehaviorRegistry lookup gives us the `@interface`
  - `:subscribe` and `:introspect` modes are not yet implemented;
    they return `{:error, :unsupported_mode}` until Phase 2+
  """
  @spec dispatch(t()) ::
          {:ok, term()}
          | :ok
          | {:error, :no_such_actor}
          | {:error, :not_ready}
          | {:error, :failed}
          | {:error, :stale_incarnation}
          | {:error, :buffer_full}
          | {:error, :activate_timeout}
          | {:error, :unsupported_mode}
          | {:error, {:invalid_args, list()}}
          | {:error, {:unknown_action, atom()}}
          | {:error, :unauthorized}
          | {:error, :cross_workspace_denied}
          | {:ok, :duplicate_ignored}
  def dispatch(%__MODULE__{mode: mode}) when mode in [:subscribe, :introspect] do
    {:error, :unsupported_mode}
  end

  def dispatch(%__MODULE__{target: target} = inv) do
    instance_uri = Ezagent.URI.instance(target)

    # C5 §3.4 DispatchPolicyPort — origin validation + canonical-admin
    # action-cap materialization + workspace owner gate fold into ONE
    # config-resolved port hook (`before_delivery/1`); the policy lives in
    # the core adapter (`Ezagent.Kind.Adapters.DispatchPolicyAdapter`),
    # never in the framework.
    with {:ok, %__MODULE__{mode: mode, ctx: ctx} = inv} <-
           dispatch_policy().before_delivery(inv) do
      cond do
        outbox().replay?(inv) ->
          dispatch_with_lazy_spawn(instance_uri, mode, inv)

        outbox().eligible?(inv) ->
          outbox().enqueue_and_attempt(inv)

        true ->
          with :ok <- maybe_idempotency_check(ctx) do
            dispatch_with_lazy_spawn(instance_uri, mode, inv)
          end
      end
    end
  end

  # codex E2E fix v2 Bug B (2026-05-29) — cold-spawn-from-snapshot on the
  # dispatch path. Pre-fix, a dispatch to a Kind URI whose process was
  # never spawned in this BEAM (ReadyGate status `:unknown`) returned
  # `{:error, :no_such_actor}` even when a `kind_snapshots` row existed.
  # Only `Ezagent.ExternalMirror.BootReconciler` rehydrated Kinds at
  # boot — every other Kind family (Agent, Session, Workspace, ...) was
  # silently invisible across BEAM restarts until something explicitly
  # called `SpawnRegistry.spawn/1` (e.g. Workspace.Loader walking
  # workspace members).
  #
  # Allen 2026-05-28 e2e symptom — DB had a `kind_snapshots` row for
  # `entity://agent/h2oslabs/codex_test_alpha`, the KindRegistry lookup
  # missed (BEAM restarted, ETS was empty), the dispatch returned
  # `:no_such_actor`. The codex e2e bridge surfaced this as "no such
  # actor (did you spawn the instance?)" — confusing because the agent
  # visibly existed in the DB.
  #
  # The fix wires `Ezagent.Kind.StateRebuilder` (Phase 1 SPEC §5.3
  # lazy-on-first-load primitive) into the dispatch chokepoint: on
  # `:unknown` we attempt to:
  #
  #   1. Check whether a `kind_snapshots` row exists for `instance_uri`.
  #      Cheap single-row PK lookup via `SnapshotStore.latest/1`. A
  #      `{:error, :not_found}` short-circuits to the legacy
  #      `:no_such_actor` (true "this URI has never existed" signal).
  #   2. If a snapshot exists, call `SpawnRegistry.spawn/1` to bring
  #      the Kind up. The spawn fn the plugin registered routes through
  #      `Kind.spawn/2` → `Kind.Server.init/1` → `Snapshot.load_or_init/3`
  #      which loads the snapshot AND merges with fresh per-Behavior
  #      init slices.
  #   3. After spawn, re-check ReadyGate. If `:ready` → proceed to
  #      `deliver_to_ready/3`. If `:not_ready` (post_init still running)
  #      and mode is `:cast` → buffer via `PendingDelivery` per the
  #      existing not-ready branch. If `:not_ready` and mode is `:call`
  #      → bounded `ReadyGate.await/2` (post-init chains are typically
  #      <100ms).
  #
  # ## Why this lives in `Invocation.dispatch/1` and NOT in the Router
  #
  # The SPEC §5.3 OQ-8 directive says "lazy-on-first-load" happens at
  # the Router level. In this codebase the Router is a Phase-2+ name
  # for what `Invocation.dispatch/1` does today; per SPEC §6 phasing
  # the chokepoint flip is staged here. When the Router lands the
  # logic moves with it — same semantics, new caller.
  #
  # ## What about cross-plugin Kinds?
  #
  # `Ezagent.ExternalMirror.BootReconciler` rebuilds ExternalMirror
  # workers at app boot via a different path (it watches for resumed
  # subscriptions, not snapshot rows). That path STAYS — Phase 4
  # explicitly kept it. The dispatch-time lazy-spawn is ADDITIONAL,
  # not a replacement; BootReconciler covers the "subscribe to peer
  # before any dispatch reaches us" case, lazy-spawn covers the
  # "dispatch lands while the Kind's process was reaped" case.
  defp dispatch_with_lazy_spawn(instance_uri, :cast, inv) do
    expected_incarnation = current_incarnation(instance_uri)

    case dispatch_cast_at_linearization_point(instance_uri, inv, expected_incarnation) do
      :ok ->
        :ok

      {:error, :buffer_full} ->
        pending_delivery_overflow(instance_uri, inv)

      {:error, :durable_pending} ->
        {:error, :not_ready}

      {:error, :failed} ->
        {:error, :failed}

      {:error, :incarnation_changed} ->
        pending_delivery_incarnation_changed(instance_uri, inv)

      {:error, :dead_target} ->
        pre_delivery_error(inv, :no_such_actor)

      {:retry, :ready} ->
        dispatch_with_lazy_spawn(instance_uri, :cast, inv)

      {:retry, :unknown} ->
        attempt_lazy_spawn_and_redispatch(instance_uri, :cast, inv)
    end
  end

  defp dispatch_with_lazy_spawn(instance_uri, mode, inv) do
    expected_incarnation = current_incarnation(instance_uri)

    case {Ezagent.ReadyGate.status(instance_uri), mode} do
      {:ready, _} ->
        deliver_to_ready(instance_uri, mode, inv, expected_incarnation)

      {:failed, _} ->
        {:error, :failed}

      {:not_ready, m} when m in [:call, :call_stream] ->
        # Readiness contract (post-lifecycle remediation, spec C-A):
        # a synchronous dispatch landing during the target's
        # `activate`/post-init window must WAIT-then-serve, not
        # fail-fast. `activate/2` now runs in post-init `handle_continue`
        # (widening the not-ready window), so the old fail-fast turned
        # a benign timing gap into a live regression — a join/list_caps/
        # subscribe issued right after a (re)spawn would spuriously see
        # `:not_ready`. We bound the wait so a genuinely stuck `activate`
        # surfaces a DISTINCT `:activate_timeout` signal (never the
        # silent `:not_ready`), preserving let-it-crash visibility.
        if outbox().replay?(inv) do
          {:error, :not_ready}
        else
          case Ezagent.ReadyGate.await(instance_uri, activate_budget_ms()) do
            :ok ->
              dispatch_with_lazy_spawn(instance_uri, mode, inv)

            {:error, :timeout} ->
              {:error, :activate_timeout}
          end
        end

      {:unknown, _} ->
        attempt_lazy_spawn_and_redispatch(instance_uri, mode, inv)
    end
  end

  # Cast readiness, incarnation validation, and the final mailbox/buffer write
  # share PendingDelivery's URI lock with Kind registration and ready/failed
  # transitions. Without this one linearization point, a replacement PID could
  # become visible while the URI still carried its predecessor's :ready row;
  # a cast would then bypass the buffer and be lost if initial persistence failed.
  defp dispatch_cast_at_linearization_point(instance_uri, inv, expected_incarnation) do
    Ezagent.PendingDelivery.with_lock(instance_uri, fn ->
      current_incarnation = current_incarnation(instance_uri)

      if current_incarnation != expected_incarnation do
        {:error, :incarnation_changed}
      else
        case {Ezagent.ReadyGate.status(instance_uri), expected_incarnation} do
          {:ready, pid} when is_pid(pid) ->
            if Process.alive?(pid) do
              GenServer.cast(pid, {:ezagent_dispatch, inv})
              :ok
            else
              {:error, :dead_target}
            end

          {:ready, :unregistered} ->
            # The readiness row outlived an already-gone target. Preserve the
            # established missing-actor contract; there is no replacement
            # incarnation here to classify as stale authority transfer.
            {:error, :dead_target}

          {:not_ready, _incarnation} ->
            if outbox().replay?(inv) do
              {:error, :durable_pending}
            else
              Ezagent.PendingDelivery.buffer_if_not_ready_locked(
                instance_uri,
                inv,
                expected_incarnation
              )
            end

          {:failed, _incarnation} ->
            {:error, :failed}

          {:unknown, :unregistered} ->
            {:retry, :unknown}

          {:unknown, _registered_pid} ->
            {:error, :incarnation_changed}
        end
      end
    end)
  end

  # The cold-spawn-from-snapshot attempt. Returns the dispatch outcome
  # after the spawn (succeeded or not) — `:no_such_actor` is returned
  # for the genuine "no snapshot + no live process" case and for any
  # spawn fn failure (so the caller sees the same shape as the
  # pre-fix path).
  defp attempt_lazy_spawn_and_redispatch(instance_uri, mode, inv) do
    case Ezagent.Kind.StateRebuilder.snapshot_exists?(instance_uri) do
      false ->
        # Genuine "never existed" — return the legacy shape so
        # existing telemetry / error handling is unchanged.
        pre_delivery_error(inv, :no_such_actor)

      true ->
        case lazy_spawn_from_snapshot(instance_uri) do
          {:ok, _pid} ->
            # The Kind is now in KindRegistry. Re-enter the gate check
            # — its ReadyGate status flipped to `:not_ready` inside
            # `Kind.Server.init/1`, which is the same starting point
            # the post-spawn paths see.
            #
            # For `:call` mode we await readiness with the same bounded
            # poll Bug A introduced — the post_init chain is short
            # (<100ms typical), and a `:call` caller is already
            # synchronously blocked so a brief await is preferable to
            # an immediate `:not_ready` error.
            case mode do
              :cast ->
                dispatch_with_lazy_spawn(instance_uri, mode, inv)

              m when m in [:call, :call_stream] ->
                unless outbox().replay?(inv) do
                  _ = Ezagent.ReadyGate.await(instance_uri, activate_budget_ms())
                end

                dispatch_with_lazy_spawn(instance_uri, mode, inv)
            end

          {:error, reason} ->
            # Spawn fn failed (e.g. plugin's Kind module not loaded,
            # supervisor down). Surface as `:no_such_actor` for
            # backwards compat but emit telemetry so operators can see
            # the underlying cause.
            :telemetry.execute(
              [:ezagent, :dispatch, :lazy_spawn_failed],
              %{},
              %{instance_uri: instance_uri, reason: reason, mode: mode}
            )

            pre_delivery_error(inv, :no_such_actor)
        end
    end
  end

  defp lazy_spawn_from_snapshot(instance_uri) do
    try do
      Ezagent.SpawnRegistry.spawn(instance_uri)
    rescue
      e -> {:error, {:lazy_spawn_raised, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:lazy_spawn_exited, reason}}
      kind, payload -> {:error, {:lazy_spawn_threw, kind, payload}}
    end
  end

  defp deliver_to_ready(instance_uri, mode, inv, expected_incarnation)
       when mode in [:call, :call_stream] do
    # Kind-death race (fix/readygate-death-race): a Kind can die in the
    # window AFTER `ReadyGate.status == :ready` but BEFORE `KindRegistry`
    # (a stdlib unique Registry) asynchronously reaps the dead pid on its
    # monitor `:DOWN`. In that window there are TWO racing sub-states,
    # decided purely by Registry-cleanup timing:
    #
    #   a. `lookup` still returns the (now dead) pid → a raw
    #      `GenServer.call` raises an uncaught `:noproc`/`:normal`/
    #      `:shutdown` EXIT — the bug (surfaced as the `em3 subscribe_from`
    #      / DefaultSessionTemplateSeed / DB-ownership-churn CI flakes).
    #   b. Registry already reaped → `lookup == :error`.
    #
    # Both are the SAME logical condition — "the :ready gate is stale, the
    # target is gone" — and the correct, semantics-preserving answer is
    # the one the pre-existing `lookup == :error` branch already gave:
    # `{:error, :no_such_actor}`. The ONLY bug is that sub-state (a)
    # CRASHED instead of returning that. So we CATCH the dead-target EXIT
    # (`call_live_target/3`) and return `:no_such_actor`, unifying (a)
    # with (b). We do NOT respawn here: a dispatch landing in the death
    # window against a gone target must report "gone", not resurrect it
    # (resurrecting it broke idempotent-terminate semantics — a 2nd
    # terminate on a gone agent must stay `:no_such_actor`). Legitimate
    # cold rehydration of a never-spawned-this-boot Kind goes through the
    # separate `{:unknown, _}` branch in `dispatch_with_lazy_spawn/3` (+
    # `ExternalMirror.BootReconciler`), which this change does NOT touch.
    case Ezagent.KindRegistry.lookup(instance_uri) do
      {:ok, ^expected_incarnation} when is_pid(expected_incarnation) ->
        pid = expected_incarnation
        timeout = inv.ctx[:deadline_ms] || 5_000

        case call_live_target(pid, {:ezagent_dispatch, inv}, timeout) do
          {:ok, result} -> result
          :dead_target -> {:error, :no_such_actor}
        end

      {:ok, _replacement_pid} ->
        {:error, :stale_incarnation}

      :error when is_pid(expected_incarnation) ->
        {:error, :no_such_actor}

      :error ->
        {:error, :no_such_actor}
    end
  end

  # Issue the `GenServer.call`, discriminating a DEAD/closing target (the
  # benign death-race case) from a real failure (propagate). Returns
  # `{:ok, result}` for any normal call return, or the `:dead_target`
  # sentinel when the target was gone — the caller maps that to the same
  # `{:error, :no_such_actor}` the missing-target path returns (it does
  # NOT respawn). Extracted so the crash-catch is unit-testable in
  # isolation (spawn → kill → call) without a Registry/ReadyGate setup —
  # that unit test is the regression test for the `(EXIT) no process` bug.
  #
  # Discrimination (the "don't swallow real errors" line):
  # - `:noproc` / `:normal` / `:shutdown` / `{:shutdown, _}` EXIT → the
  #   target died or is closing → `:dead_target` (→ `:no_such_actor`).
  # - `:timeout` EXIT → target is alive-but-slow; masking it would hide a
  #   genuinely stuck handler → RE-RAISE.
  # - any other EXIT reason (a handler crash) → RE-RAISE.
  @doc false
  @spec call_live_target(pid(), term(), timeout()) :: {:ok, term()} | :dead_target
  def call_live_target(pid, message, timeout) do
    # Fast-path: skip the call entirely if the pid is already known dead.
    # (TOCTOU-safe — the try/catch below is the actual guarantee; this
    # only avoids a guaranteed-failing round-trip.)
    if Process.alive?(pid) do
      try do
        {:ok, GenServer.call(pid, message, timeout)}
      catch
        :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
          :dead_target

        :exit, {{:shutdown, _}, _call} ->
          :dead_target
      end
    else
      :dead_target
    end
  end

  # PendingDelivery overflow (PR #1259 codex review item 2). A `:cast` to a
  # `:not_ready` target whose buffer is at cap is a REAL drop — never return
  # `:ok` for it. Loud unconditional Logger.error (not just the reply:-:ignore
  # telemetry path), a `[:ezagent, :dispatch, :pending_delivery_overflow]`
  # telemetry event, and the Decision #67 DLQ row (best-effort — the DLQ write
  # is a Repo insert; a DB hiccup must not mask the error return). Returns
  # `{:error, :buffer_full}` — the established cast pre-delivery error shape.
  defp pending_delivery_overflow(instance_uri, %__MODULE__{} = inv) do
    Logger.error(
      "Ezagent.Invocation: PendingDelivery buffer FULL (#{Ezagent.PendingDelivery.max_per_uri()}) " <>
        "for not-ready target=#{URI.to_string(inv.target)} " <>
        "instance=#{URI.to_string(instance_uri)} — cast invocation DROPPED " <>
        "(recorded to DLQ reason=:buffer_full)"
    )

    :telemetry.execute(
      [:ezagent, :dispatch, :pending_delivery_overflow],
      %{},
      %{target: inv.target, instance_uri: instance_uri, mode: :cast}
    )

    try do
      dead_letter().put(:buffer_full, inv)
    rescue
      e ->
        Logger.error(
          "Ezagent.Invocation: DLQ write for dropped buffer_full cast FAILED: " <>
            Exception.message(e)
        )
    catch
      kind, payload ->
        Logger.error(
          "Ezagent.Invocation: DLQ write for dropped buffer_full cast FAILED: " <>
            "#{inspect({kind, payload})}"
        )
    end

    {:error, :buffer_full}
  end

  defp pending_delivery_incarnation_changed(instance_uri, %__MODULE__{} = inv) do
    Logger.error(
      "Ezagent.Invocation: cast target incarnation CHANGED before delivery commit " <>
        "target=#{URI.to_string(inv.target)} instance=#{URI.to_string(instance_uri)} — " <>
        "cast invocation DROPPED (recorded to DLQ reason=:stale_incarnation)"
    )

    :telemetry.execute(
      [:ezagent, :dispatch, :pending_delivery_stale_incarnation],
      %{},
      %{target: inv.target, instance_uri: instance_uri, mode: :cast}
    )

    try do
      dead_letter().put(:stale_incarnation, inv)
    rescue
      e ->
        Logger.error(
          "Ezagent.Invocation: DLQ write for stale-incarnation cast FAILED: " <>
            Exception.message(e)
        )
    catch
      kind, payload ->
        Logger.error(
          "Ezagent.Invocation: DLQ write for stale-incarnation cast FAILED: " <>
            "#{inspect({kind, payload})}"
        )
    end

    {:error, :stale_incarnation}
  end

  defp current_incarnation(instance_uri) do
    case Ezagent.KindRegistry.lookup(instance_uri) do
      {:ok, pid} when is_pid(pid) -> pid
      _ -> :unregistered
    end
  end

  defp pre_delivery_error(%__MODULE__{} = inv, reason) do
    log_unobservable_pre_delivery_cast_error(inv, reason)
    {:error, reason}
  end

  defp log_unobservable_pre_delivery_cast_error(
         %__MODULE__{mode: :cast, ctx: %{reply: :ignore}} = inv,
         reason
       ) do
    instance_uri = Ezagent.URI.instance(inv.target)

    :telemetry.execute(
      [:ezagent, :dispatch, :cast_failed],
      %{},
      %{
        target: inv.target,
        instance_uri: instance_uri,
        mode: :cast,
        reason: reason,
        stage: :pre_delivery
      }
    )

    Logger.error(
      "Ezagent.Invocation: fire-and-forget cast dispatch FAILED before delivery " <>
        "target=#{URI.to_string(inv.target)} instance=#{URI.to_string(instance_uri)} " <>
        "reason=#{inspect(reason)}"
    )

    :ok
  end

  defp log_unobservable_pre_delivery_cast_error(%__MODULE__{}, _reason), do: :ok

  defp maybe_idempotency_check(%{idempotency_key: key}) when is_binary(key) do
    if Ezagent.Idempotency.seen?(key) do
      {:ok, :duplicate_ignored}
    else
      :ok = Ezagent.Idempotency.record(key)
      :ok
    end
  end

  defp maybe_idempotency_check(_ctx), do: :ok

  # --- reply -------------------------------------------------------------

  @doc """
  Route a result back to the caller per `ctx.reply`.

  Phase 1 cases:
  - `{:caller_inbox, pid}` — `send(pid, {:ezagent_reply, result})`
  - `{:phoenix_pubsub, topic}` — `Phoenix.PubSub.broadcast(EzagentCore.PubSub,
    topic, {:ezagent_reply, result})` — allowed only for view fan-out topics
    (§5.7.6); audit:stream is the canonical example
  - `:ignore` — no-op (silent success)

  Later phases (`:phoenix_channel`, `:plug_conn`, `:stdio_pipe`,
  `:mcp_response`) raise `ArgumentError` for now.
  """
  @spec reply(ctx(), term()) :: :ok | no_return()
  def reply(%{reply: {:caller_inbox, pid}}, result) when is_pid(pid) do
    send(pid, {:ezagent_reply, result})
    :ok
  end

  def reply(%{reply: {:phoenix_pubsub, topic}}, result) when is_binary(topic) do
    Phoenix.PubSub.broadcast(pubsub(), topic, {:ezagent_reply, result})
    :ok
  end

  def reply(%{reply: :ignore}, _result), do: :ok

  def reply(%{reply: {kind, _}}, _result)
      when kind in [:phoenix_channel, :plug_conn, :stdio_pipe, :mcp_response] do
    raise ArgumentError,
          "reply target #{inspect(kind)} not yet implemented in Phase 1 — arrives with its adapter"
  end

  # C5 §3.4 pubsub injection — the PubSub server name is a config injection,
  # never a literal spine reference. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to `EzagentCore.PubSub`.
  defp pubsub, do: Application.fetch_env!(:ezagent_actor, :pubsub)

  # C5 §3.4 DeadLetterPort — DLQ writes go through the config-resolved port,
  # never the literal `Ezagent.DLQ` spine. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.DeadLetterAdapter`.
  defp dead_letter, do: Application.fetch_env!(:ezagent_actor, :dead_letter)

  # C5 §3.4 OutboxPort — cap-delivery outbox calls go through the
  # config-resolved port, never the literal `Ezagent.Cap.DeliveryOutbox`
  # spine. Wired at core boot (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.OutboxAdapter`.
  defp outbox, do: Application.fetch_env!(:ezagent_actor, :outbox)

  # C5 §3.4 DispatchPolicyPort — pre-delivery policy (origin validate +
  # admin-cap materialization + owner gate) goes through the config-resolved
  # port, never the literal `Ezagent.DispatchOrigin` /
  # `Ezagent.WorkspaceOwnerGate` / `Ezagent.Cap` spine. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.DispatchPolicyAdapter`.
  defp dispatch_policy, do: Application.fetch_env!(:ezagent_actor, :dispatch_policy)
end
