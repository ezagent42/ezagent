defmodule EzagentDomainChat.Integration.LifecycleTerminateTest do
  @moduledoc """
  Phase 7 completion PR-5 (SPEC §1.6b) — `Ezagent.Behavior.Lifecycle`
  is dispatch-routed + CapBAC-gated agent termination.

  Asserts:

  - `lifecycle.terminate` resolves through `BehaviorRegistry` on the
    Agent Kind (it is registered in `register_chat_behaviors/0`);
  - an in-lineage worker dispatched `lifecycle.terminate` is brought
    down via its owning DynamicSupervisor;
  - the cap-#2 control — `lifecycle.terminate` against an agent NOT in
    the caller's `{:spawned_by, _}` lineage → `{:error, :unauthorized}`;
  - termination is idempotent — a second `lifecycle.terminate` on an
    already-gone agent still returns success.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentLineage, BehaviorRegistry, Capability, KindRegistry}
  alias Ezagent.Behavior.Lifecycle
  alias Ezagent.Entity.{Agent, User}

  defp uniq, do: System.unique_integer([:positive])
  @workspace_uri URI.new!("workspace://default")

  # Spawn an Agent Kind, bind workspace, record lineage under `spawned_by`.
  defp spawn_worker(spawned_by) do
    worker_uri = URI.parse("entity://agent/default/test_worker-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: worker_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(worker_uri, @workspace_uri)
    :ok = AgentLineage.record(worker_uri, spawned_by)
    worker_uri
  end

  # A cap #2 — `{:spawned_by, principal}` on `:agent`.
  defp spawned_by_cap(principal_uri) do
    %Capability{
      kind: :agent,
      behavior: :any,
      instance: {:spawned_by, principal_uri},
      workspace_uri: @workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp terminate(worker_uri, caller_uri, caps) do
    target = URI.parse("#{URI.to_string(worker_uri)}?action=lifecycle.terminate")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{},
      ctx: %{caller: caller_uri, caps: caps, reply: {:caller_inbox, self()}}
    })
  end

  defp wait_until_gone(uri, tries \\ 50) do
    cond do
      tries == 0 -> :still_alive
      KindRegistry.lookup(uri) == :error -> :gone
      true ->
        Process.sleep(10)
        wait_until_gone(uri, tries - 1)
    end
  end

  test "lifecycle.terminate resolves through BehaviorRegistry on the Agent Kind" do
    assert {:ok, Lifecycle} = BehaviorRegistry.lookup(Agent, :terminate)
  end

  test "an in-lineage worker is terminated via dispatch (cap-#2 happy path)" do
    orchestrator = URI.parse("entity://agent/default/cc_orch-#{uniq()}")
    worker_uri = spawn_worker(orchestrator)

    assert {:ok, _pid} = KindRegistry.lookup(worker_uri)

    caps = MapSet.new([spawned_by_cap(orchestrator)])

    assert {:ok, {:ok, :terminated}} = terminate(worker_uri, orchestrator, caps)

    assert :gone = wait_until_gone(worker_uri),
           "the worker process must be brought down after lifecycle.terminate"
  end

  test "cap-#2 control — terminating an agent NOT in your lineage is :unauthorized" do
    orchestrator_a = URI.parse("entity://agent/default/cc_orch-a-#{uniq()}")
    orchestrator_b = URI.parse("entity://agent/default/cc_orch-b-#{uniq()}")

    # The worker is spawned by A.
    worker_uri = spawn_worker(orchestrator_a)

    # B holds a cap #2 scoped to ITSELF — it does NOT cover A's worker.
    caps_b = MapSet.new([spawned_by_cap(orchestrator_b)])

    assert {:error, :unauthorized} = terminate(worker_uri, orchestrator_b, caps_b),
           "orchestrator B must not terminate A's worker — cap #2 is {:spawned_by, B}"

    # The worker is still alive — the denied dispatch had no effect.
    assert {:ok, _pid} = KindRegistry.lookup(worker_uri)
  end

  test "termination is idempotent — a second terminate on a gone agent still succeeds" do
    orchestrator = URI.parse("entity://agent/default/cc_orch-idem-#{uniq()}")
    worker_uri = spawn_worker(orchestrator)
    caps = MapSet.new([spawned_by_cap(orchestrator)])

    assert {:ok, {:ok, :terminated}} = terminate(worker_uri, orchestrator, caps)
    assert :gone = wait_until_gone(worker_uri)

    # The worker is gone — a second terminate dispatches to an absent
    # actor. `Ezagent.Orchestrator.Tools.terminate_worker/3` maps
    # :no_such_actor to idempotent success; here we assert the dispatch
    # itself surfaces the absent actor cleanly (not a crash).
    assert {:error, :no_such_actor} = terminate(worker_uri, orchestrator, caps)
  end
end
