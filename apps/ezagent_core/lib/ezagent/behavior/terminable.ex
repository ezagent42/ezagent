defmodule Ezagent.ActionSet.Terminable do
  @moduledoc """
  Terminable Behavior — dispatchable, CapBAC-gated Kind termination
  (Phase 7 completion SPEC §1.6b, codex rev-5 HIGH-3).

  ## Why this Behavior exists

  The orchestrator's `remove_agent_slot` / `update_agent_template` tools
  must terminate a worker. Before this Behavior there was no termination
  action — `Ezagent.Entity.Agent.behaviors/0` is `[Chat, Identity]`
  (`Pty` registered separately), so `BehaviorRegistry.lookup(Agent,
  :terminate)` returned `:error`. A bare `DynamicSupervisor.terminate_child`
  bypasses dispatch + CapBAC entirely — an orchestrator could kill ANY
  agent, not just its own workers.

  `Ezagent.ActionSet.Terminable` is the fix: a small CORE Behavior (no
  plugin references — it lives in `ezagent_core` so any Kind can carry
  it) whose single `:terminate` action routes through `Invocation.dispatch/1`,
  so CapBAC step 5.5 enforces the caller's cap on
  `entity://agent/...?action=lifecycle.terminate` — the orchestrator's
  `{:spawned_by, orchestrator}` cap (#2) is what permits it to terminate
  its OWN workers and nothing else.

  ## Naming (Phase B — SPEC `2026-05-29-lifecycle-hooks-design.md` §9 OQ-6 / §11)

  Renamed from `Ezagent.ActionSet.Lifecycle` on the Lifecycle migration.
  The handler operates purely on `kind_module` / `supervisor/0` — it is
  fully **Kind-generic** (terminates ANY Kind's supervised process via
  dispatch + CapBAC; it only happens to be *registered on* the Agent Kind
  today). The correct name is therefore a Kind-layer capability name in
  the `Enumerable`/`Collectable` idiom — `Terminable` = "this Kind can be
  terminated through the gated path." Per NP-2 it must NOT name `Agent`
  (an upper-layer composition concept that does not exist at the R/B/K
  layer). The action namespace (`?action=lifecycle.terminate`) and the
  persisted slice key (`:lifecycle`) are UNCHANGED — the latter is
  preserved via the `state_slice: :lifecycle` override (snapshot-compat,
  SPEC §7 OQ-7); the former is a cosmetic dispatch label parsed from the
  URI (the runtime resolves the handler by the `:terminate` action atom,
  not by the `lifecycle.` prefix), so existing call sites that construct
  `?action=lifecycle.terminate` are untouched.

  ## State slice — `:lifecycle` (preserved via override)

  A trivial slice (`%{terminations: 0}`). The Behavior is registered on
  the Agent Kind after-the-fact via `CapabilityRegistry.register/3` (it is
  NOT in `Agent.behaviors/0`), so `Ezagent.Kind.Snapshot.init_fresh/2`
  skips `create/1` — the runtime hands an empty `%{}` state slice. The
  counter is lazy-seeded via `ctx.read.(:terminations, 0)` so the Behavior
  works for any Kind it is registered against. There are NO transients.

  ## Action — `:terminate`

  `:terminate` (`:call` mode) terminates the target Kind's supervised pid
  via its owning `DynamicSupervisor` (resolved from the Kind module's
  `supervisor/0` callback). It is **idempotent** — a target that is
  already gone still returns `{:ok, :terminated}`.

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

  ## Migration to `use Ezagent.Lifecycle` (Phase B — 2026-05-29)

  Converted from `use Ezagent.ActionSet` + `init_slice/1` to
  `use Ezagent.Lifecycle` + `create/1`. The action `:terminate`,
  the `handle_terminate/2` handler, the effect list, and the
  deferred-termination + best-effort-notify side-effect functions are
  UNCHANGED.

  The deferred-termination pattern is preserved as a `{:effect, mfa,
  args}` side effect — `apply_effects/2` runs `:effect` entries
  fire-and-forget AFTER the slice mutation lands. `Task.start/1` is
  what spawns the unlinked task; the 20ms sleep window inside the
  task is what lets `GenServer.call`'s reply win the race. Using a
  `{:terminate, :self}` effect was rejected — the runtime executes
  `:terminate` effects via `Ezagent.Kind.terminate/1` SYNCHRONOUSLY
  before the dispatch reply returns, which is exactly the race the
  detached-Task pattern works around. The Terminable Behavior is NOT
  the framework's terminate mechanism; it is one client of it.

  The spawning-principal notification is also a `{:effect, mfa, args}`
  side effect — it's best-effort, observational, and must not block
  the dispatch reply. Errors inside `Ezagent.Notifications.notify/2`
  are still rescued/caught inside `notify_spawning_principal/1` so a
  PubSub-down test fixture doesn't fail the action.
  """

  # lifecycle:state_slice_override — keep the persisted slice key `:lifecycle`
  # stable across the rename for snapshot-compat (SPEC §7 OQ-7). The
  # module-name-derived default would be `:terminable`, which would orphan
  # every existing `:lifecycle` snapshot slice; the explicit override pins it.
  use Ezagent.Lifecycle, state_slice: :lifecycle

  require Logger

  # NOTE: the action `:returns` declares the conceptual response shape
  # for InterfaceValidator / docs surfaces. The wire-level result the
  # handler returns is the literal 2-tuple `{:ok, :terminated}` — callers
  # (`Orchestrator.Tools`, the LV `TerminalLive.handle_event/3` terminate
  # flow) pattern-match on `{:ok, {:ok, :terminated}}` (outer `{:ok, _}`
  # is the dispatch wrapper; inner `{:ok, :terminated}` is the action
  # result). The `:returns` schema is the human-readable contract; the
  # runtime does NOT enforce it on the result shape today.
  action(:terminate,
    args: %{},
    returns: %{terminated: :boolean},
    caps: [:terminate],
    modes: [:call],
    description:
      "terminate the target Kind's supervised process (idempotent — already-gone is :ok)"
  )

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Terminable is registered on the Agent Kind (per
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

  # create/1 — FIRST-EVER existence (Lifecycle): build the PERSISTENT
  # state (the termination counter). No transients: this Behavior holds
  # no pids/refs/handles of its own — the detached termination Task is
  # fire-and-forget, never tracked in state. `activate/2` is the macro's
  # no-op default (no transients to rebuild on restart).
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{terminations: 0}}

  def handle_terminate(_args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    kind_module = Map.get(ctx, :kind_module)
    prev_terminations = ctx.read.(:terminations, 0)

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
    # The `result` value `{:ok, :terminated}` is what the caller's
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
            "Ezagent.ActionSet.Terminable: :agent_terminated notify to " <>
              "#{URI.to_string(parent_uri)} raised #{inspect(error)}; " <>
              "termination of #{URI.to_string(agent_uri)} proceeds"
          )

          :ok
      catch
        kind, reason ->
          Logger.warning(
            "Ezagent.ActionSet.Terminable: :agent_terminated notify to " <>
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

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
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
    # Live pid via the public operator plane (§2.2 `Kind.list_instances/0`) — the
    # actor-internal-free replacement for the `KindRegistry.lookup/1` pid
    # resolution the supervised terminate needs.
    uri_str = URI.to_string(self_uri)

    case Enum.find(Ezagent.Kind.list_instances(), fn {u, _meta} -> u == uri_str end) do
      {_u, %{pid: pid}} ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            # The child is not under `supervisor` (or already gone) —
            # terminate by pid directly so the worker still goes down.
            _ = Process.exit(pid, :shutdown)
            :ok
        end

      nil ->
        # Already terminated — idempotent success.
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Ezagent.ActionSet.Terminable: terminate of #{URI.to_string(self_uri)} " <>
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
