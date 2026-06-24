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
          required(:caps) => MapSet.t(Ezagent.Capability.t()),
          required(:reply) => reply_target(),
          optional(:trace_id) => String.t(),
          optional(:deadline_ms) => pos_integer(),
          optional(:idempotency_key) => String.t()
        }

  @enforce_keys [:target, :mode, :args, :ctx]
  defstruct [:target, :mode, :args, :ctx]

  @type t :: %__MODULE__{
          target: URI.t(),
          mode: mode(),
          args: map(),
          ctx: ctx()
        }

  # --- dispatch ----------------------------------------------------------

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

  def dispatch(%__MODULE__{target: target, mode: mode, ctx: ctx} = inv) do
    instance_uri = Ezagent.URI.instance(target)

    with :ok <- maybe_idempotency_check(ctx) do
      dispatch_with_lazy_spawn(instance_uri, mode, inv)
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
  defp dispatch_with_lazy_spawn(instance_uri, mode, inv) do
    case {Ezagent.ReadyGate.status(instance_uri), mode} do
      {:ready, _} ->
        deliver_to_ready(instance_uri, mode, inv)

      {:failed, _} ->
        {:error, :failed}

      {:not_ready, :cast} ->
        # Buffer for delivery once instance announces ready.
        Ezagent.PendingDelivery.buffer(instance_uri, inv)
        :ok

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
        case Ezagent.ReadyGate.await(instance_uri, 5_000) do
          :ok ->
            dispatch_with_lazy_spawn(instance_uri, mode, inv)

          {:error, :timeout} ->
            {:error, :activate_timeout}
        end

      {:unknown, _} ->
        attempt_lazy_spawn_and_redispatch(instance_uri, mode, inv)
    end
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
        {:error, :no_such_actor}

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
                _ = Ezagent.ReadyGate.await(instance_uri, 5_000)
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

            {:error, :no_such_actor}
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

  defp deliver_to_ready(instance_uri, :cast, inv) do
    case Ezagent.KindRegistry.lookup(instance_uri) do
      {:ok, pid} ->
        GenServer.cast(pid, {:ezagent_dispatch, inv})
        :ok

      :error ->
        {:error, :no_such_actor}
    end
  end

  defp deliver_to_ready(instance_uri, mode, inv) when mode in [:call, :call_stream] do
    case Ezagent.KindRegistry.lookup(instance_uri) do
      {:ok, pid} ->
        timeout = inv.ctx[:deadline_ms] || 5_000
        GenServer.call(pid, {:ezagent_dispatch, inv}, timeout)

      :error ->
        {:error, :no_such_actor}
    end
  end

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
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic, {:ezagent_reply, result})
    :ok
  end

  def reply(%{reply: :ignore}, _result), do: :ok

  def reply(%{reply: {kind, _}}, _result)
      when kind in [:phoenix_channel, :plug_conn, :stdio_pipe, :mcp_response] do
    raise ArgumentError,
          "reply target #{inspect(kind)} not yet implemented in Phase 1 — arrives with its adapter"
  end
end
