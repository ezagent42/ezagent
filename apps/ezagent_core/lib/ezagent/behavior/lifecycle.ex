defmodule Ezagent.Behavior.Lifecycle do
  @moduledoc """
  Lifecycle Behavior — dispatchable, CapBAC-gated agent termination
  (Phase 7 completion SPEC §1.6b, codex rev-5 HIGH-3).

  ## Why this Behavior exists

  The orchestrator's `remove_agent_slot` / `update_agent_template` tools
  must terminate a worker. Before this Behavior there was no lifecycle
  action — `Ezagent.Entity.Agent.behaviors/0` is `[Chat, Identity]`
  (`Pty` registered separately), so `BehaviorRegistry.lookup(Agent,
  :terminate)` returned `:error`. A bare `DynamicSupervisor.terminate_child`
  bypasses dispatch + CapBAC entirely — an orchestrator could kill ANY
  agent, not just its own workers.

  `Ezagent.Behavior.Lifecycle` is the fix: a small CORE Behavior (no
  plugin references — it lives in `ezagent_core` so any Kind can carry
  it) whose single `:terminate` action routes through `Invocation.dispatch/1`,
  so CapBAC step 5.5 enforces the caller's cap on
  `entity://agent/...?action=lifecycle.terminate` — the orchestrator's
  `{:spawned_by, orchestrator}` cap (#2) is what permits it to terminate
  its OWN workers and nothing else.

  ## State slice — `:lifecycle`

  A trivial slice (`%{terminations: 0}`). The Behavior is registered on
  the Agent Kind after-the-fact via `BehaviorRegistry.register/3` (it is
  NOT in `Agent.behaviors/0`), so `Ezagent.Kind.Snapshot.init_fresh/2`
  skips `init_slice/1` — the runtime hands an empty `%{}` slice. The
  counter is lazy-seeded via `Map.update/4` so the Behavior works for
  any Kind it is registered against.

  ## Action — `:terminate`

  `:terminate` (`:call` mode) terminates the target Agent Kind's
  supervised pid via its owning `DynamicSupervisor` (resolved from the
  Kind module's `supervisor/0` callback). It is **idempotent** — a
  target that is already gone still returns `{:ok, :terminated}`.

  ### Why the termination is deferred

  The `:terminate` action runs INSIDE the target Kind's GenServer
  (dispatch routed `?action=lifecycle.terminate` to the target's own
  pid). Terminating the pid synchronously from within the action handler
  would kill the process before the dispatch `GenServer.call` reply is
  sent — the caller would see `{:error, :no_such_actor}` / a timeout
  instead of `{:ok, :terminated}`. So the action returns the success
  result and schedules the actual `DynamicSupervisor.terminate_child` in
  a detached task; by the time the supervisor acts, the dispatch reply
  has already been delivered. The detached task is unlinked so a
  termination race never crashes the dispatch path.

  ## Migration to §2.2 declarative contract (Phase 2.5 — 2026-05-28)

  Per SPEC `2026-05-28-router-behavior-kind-architecture.md` §6.2,
  migrated from `@behaviour Ezagent.Behavior` + `invoke/4` to
  `use Ezagent.Behavior` + `action/3` + `handle_terminate/2`.

  The deferred-termination pattern is preserved as a `{:effect, mfa,
  args}` side effect — `apply_effects/2` runs `:effect` entries
  fire-and-forget AFTER the slice mutation lands. `Task.start/1` is
  what spawns the unlinked task; the 20ms sleep window inside the
  task is what lets `GenServer.call`'s reply win the race. Using a
  `{:terminate, :self}` effect was rejected — the runtime executes
  `:terminate` effects via `Ezagent.Kind.terminate/1` SYNCHRONOUSLY
  before the dispatch reply returns, which is exactly the race the
  detached-Task pattern works around. The Lifecycle Behavior is NOT
  the framework's terminate mechanism; it is one client of it.

  The spawning-principal notification is also a `{:effect, mfa, args}`
  side effect — it's best-effort, observational, and must not block
  the dispatch reply. Errors inside `Ezagent.Notifications.notify/2`
  are still rescued/caught inside `notify_spawning_principal/1` so a
  PubSub-down test fixture doesn't fail the action.
  """

  use Ezagent.Behavior

  require Logger

  # NOTE: the action `:returns` declares the conceptual response shape
  # for InterfaceValidator / docs surfaces. The wire-level result the
  # legacy `invoke/4` clause returned was the literal 2-tuple
  # `{:ok, :terminated}` — callers (`Orchestrator.Tools`, the LV
  # `TerminalLive.handle_event/3` terminate flow) pattern-match on
  # `{:ok, {:ok, :terminated}}` (outer `{:ok, _}` is the dispatch
  # wrapper; inner `{:ok, :terminated}` is the action result). The
  # new-contract handler returns the exact same inner tuple to keep
  # those call sites unchanged. The `:returns` schema is the
  # human-readable contract; the runtime does NOT enforce it on the
  # result shape today.
  action :terminate,
    args: %{},
    returns: %{terminated: :boolean},
    caps: [:terminate],
    modes: [:call],
    description:
      "terminate the target Kind's supervised process (idempotent — already-gone is :ok)"

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Lifecycle is registered on the Agent Kind (per
  # `Ezagent.Domain.Chat.Application` register_lifecycle_behavior) —
  # kind axis is `:agent`. workspace_scoped? = true (default): an
  # orchestrator's `{:spawned_by, principal_uri}` cap is workspace-
  # scoped via the underlying URI, so cross-workspace termination is
  # blocked structurally. The macro-derived default would yield `:any`;
  # we override to keep the `:agent` axis the CapabilityRegistry expects.
  def required_caps do
    %{
      terminate: Ezagent.Capability.cap(:agent, __MODULE__, :terminate)
    }
  end

  def state_slice, do: :lifecycle

  def init_slice(_args), do: %{terminations: 0}

  def handle_terminate(_args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    kind_module = Map.get(ctx, :kind_module)
    prev_terminations = ctx[:read].(:terminations, 0)

    # The handler returns side-effects via the effect grammar:
    #
    #   1. `{:set, :terminations, prev+1}` — counter bump, persisted via
    #      the standard snapshot path.
    #   2. `{:effect, {__MODULE__, :notify_spawning_principal}, [self_uri]}`
    #      — best-effort notify to the spawning principal (orchestrator
    #      / user); rescues + telemetry are inside the function body.
    #   3. `{:effect, {__MODULE__, :schedule_termination}, [self_uri, kind_module]}`
    #      — detached Task that, after 20ms, terminates the Kind's
    #      supervised pid. The sleep window lets the dispatch reply
    #      win the race so the caller sees `{:ok, :terminated}`.
    #
    # The `result` value `%{terminated: true}` is what the caller's
    # dispatch returns; the effect ordering inside `apply_effects/2`
    # runs `:set` first (slice mutation), then `:effect` (fire-and-
    # forget side effects in declared order). Both fire BEFORE the
    # dispatch reply is sent, but `schedule_termination` immediately
    # spawns an unlinked Task and returns — its actual termination
    # work happens 20ms later, well after the reply has been sent.
    {:ok, {:ok, :terminated},
     [
       {:set, :terminations, prev_terminations + 1},
       {:effect, {__MODULE__, :notify_spawning_principal}, [self_uri]},
       {:effect, {__MODULE__, :schedule_termination}, [self_uri, kind_module]}
     ]}
  end

  # --- internals ---------------------------------------------------------

  # Notifier/flash audit 2026-05-24 — todo.md "Notifications consumer
  # coverage" — surface termination to the spawning principal so the
  # orchestrator (or whoever invoked the spawn) learns the worker is
  # going away. Lineage parent comes from `Ezagent.AgentLineage` (the
  # same SoT the `{:spawned_by, _}` cap shape uses). Gated by
  # `user_uri?/1`: agents don't have inboxes, so a non-user spawning
  # principal (orchestrator agent) generates no notification. Wrapped
  # in `try` so a notify failure (e.g. test sandbox without PubSub)
  # never blocks termination — the dispatch reply must still go out.
  #
  # Marked @doc false so the function is invocable by the effect
  # grammar's `{:effect, {Mod, :fun}, args}` shape but doesn't pollute
  # the Behavior's public API surface (the legacy contract had this as
  # `defp`; new-contract effects need `def`).
  @doc false
  def notify_spawning_principal(%URI{} = agent_uri) do
    with {:ok, %URI{} = parent_uri} <- Ezagent.AgentLineage.lookup(agent_uri),
         true <- user_uri?(parent_uri) do
      try do
        _ =
          Ezagent.Notifications.notify(parent_uri, %{
            type: :agent_terminated,
            body: %{
              text: "Agent #{URI.to_string(agent_uri)} terminated.",
              agent_uri: agent_uri
            },
            source: __MODULE__
          })
      rescue
        error ->
          # Codex r1 MED (med-batch 2026-05-26) — P27 server-side
          # observability: rescue keeps termination non-blocking but
          # the operator must be able to debug "user reports they
          # never got the agent-terminated notification". Log type +
          # target + exception summary.
          Logger.warning(
            "Ezagent.Behavior.Lifecycle: :agent_terminated notify to " <>
              "#{URI.to_string(parent_uri)} raised #{inspect(error)}; " <>
              "termination of #{URI.to_string(agent_uri)} proceeds"
          )

          :ok
      catch
        kind, reason ->
          Logger.warning(
            "Ezagent.Behavior.Lifecycle: :agent_terminated notify to " <>
              "#{URI.to_string(parent_uri)} threw #{inspect({kind, reason})}; " <>
              "termination of #{URI.to_string(agent_uri)} proceeds"
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  def notify_spawning_principal(_), do: :ok

  defp user_uri?(%URI{scheme: "entity", host: "user"}), do: true
  defp user_uri?(_), do: false

  # Schedule the supervised-child termination AFTER the dispatch reply
  # has been delivered. Running it inline would kill this GenServer
  # before `GenServer.call/3` could reply. The task is unlinked +
  # short-sleeped so the reply wins the race; an already-gone target is
  # a no-op (idempotent).
  @doc false
  def schedule_termination(%URI{} = self_uri, kind_module) when is_atom(kind_module) do
    supervisor = resolve_supervisor(kind_module)

    {:ok, _pid} =
      Task.start(fn ->
        # Yield so the synchronous dispatch reply is sent before the
        # process is brought down.
        Process.sleep(20)
        terminate_supervised(self_uri, supervisor)
      end)

    :ok
  end

  def schedule_termination(_self_uri, _kind_module), do: :ok

  defp resolve_supervisor(kind_module) do
    if function_exported?(kind_module, :supervisor, 0) do
      kind_module.supervisor()
    else
      Ezagent.KindSupervisor
    end
  end

  # Idempotent: look up the live pid, terminate it via the owning
  # DynamicSupervisor. An absent pid (already terminated) is success.
  defp terminate_supervised(%URI{} = self_uri, supervisor) do
    case Ezagent.KindRegistry.lookup(self_uri) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            # The child is not under `supervisor` (or already gone) —
            # terminate by pid directly so the worker still goes down.
            _ = Process.exit(pid, :shutdown)
            :ok
        end

      :error ->
        # Already terminated — idempotent success.
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Ezagent.Behavior.Lifecycle: terminate of #{URI.to_string(self_uri)} " <>
          "raised #{inspect(error)}; treating as terminated"
      )

      :ok
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): admin-only
  # Behavior — no per-entity owner; only bootstrap admin grants
  # via §5.2 admin branch. Test/demo Behaviors + system control
  # surfaces fall here pending dedicated SPEC for any specific
  # owner model they need.
  def data_owner(_), do: :no_owner
end
