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
  """

  @behaviour Ezagent.Behavior

  require Logger

  @impl Ezagent.Behavior
  def actions, do: [:terminate]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:terminate,
       "terminate the target Kind's supervised process (idempotent — already-gone is :ok)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :lifecycle

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{terminations: 0}

  @impl Ezagent.Behavior
  def invoke(:terminate, slice, _args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    kind_module = Map.get(ctx, :kind_module)

    schedule_termination(self_uri, kind_module)

    {:ok, bump(slice), {:ok, :terminated}}
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      terminate: %{
        description:
          "Terminate the target Agent Kind's supervised process via its owning " <>
            "DynamicSupervisor. Idempotent — an already-absent target returns " <>
            "{:ok, :terminated}",
        args: %{},
        returns: %{terminated: :boolean},
        modes: [:call]
      }
    }
  end

  # --- internals ---------------------------------------------------------

  # Lazy-seed the counter — the Behavior is registered after-the-fact on
  # the Agent Kind, so the runtime may hand us an empty `%{}` slice.
  defp bump(slice), do: Map.update(slice, :terminations, 1, &(&1 + 1))

  # Schedule the supervised-child termination AFTER the dispatch reply
  # has been delivered. Running it inline would kill this GenServer
  # before `GenServer.call/3` could reply. The task is unlinked +
  # short-sleeped so the reply wins the race; an already-gone target is
  # a no-op (idempotent).
  defp schedule_termination(%URI{} = self_uri, kind_module) when is_atom(kind_module) do
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

  defp schedule_termination(_self_uri, _kind_module), do: :ok

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
  @impl Ezagent.Behavior
  def data_owner(_), do: :no_owner
end
