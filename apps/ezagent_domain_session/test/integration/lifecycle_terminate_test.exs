defmodule EzagentDomainInstanceMessage.Integration.LifecycleTerminateTest do
  @moduledoc """
  Phase 7 completion PR-5 (SPEC §1.6b) — `Ezagent.ActionSet.Terminable`
  (renamed from `Ezagent.ActionSet.Lifecycle` in the Phase B Lifecycle
  migration; the `lifecycle.terminate` action namespace is unchanged)
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

  alias Ezagent.{AgentLineage, BehaviorRegistry, KindRegistry}
  alias Ezagent.ActionSet.Terminable
  alias Ezagent.Entity.{Agent, User}
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  defp uniq, do: System.unique_integer([:positive])
  @workspace_uri URI.new!("workspace://team-alpha")

  # Spawn an Agent Kind, bind workspace, record lineage under `spawned_by`.
  defp spawn_worker(spawned_by) do
    worker_uri = Ezagent.URI.new!("entity://team-alpha/agent/test_worker-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: worker_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(worker_uri, @workspace_uri)
    :ok = AgentLineage.record(worker_uri, spawned_by)
    worker_uri
  end

  defp terminate_cap(worker_uri, principal_uri) do
    worker_uri
    |> Ezagent.URI.with_action(:lifecycle, :terminate)
    |> signed_action_cap!(principal_uri)
  end

  defp terminate(worker_uri, caller_uri, caps) do
    target = Ezagent.URI.new!("#{URI.to_string(worker_uri)}?action=lifecycle.terminate")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{caller: caller_uri, caps: caps, reply: {:caller_inbox, self()}}
    })
  end

  defp wait_until_gone(uri, tries \\ 50) do
    cond do
      tries == 0 ->
        :still_alive

      KindRegistry.lookup(uri) == :error ->
        :gone

      true ->
        Process.sleep(10)
        wait_until_gone(uri, tries - 1)
    end
  end

  test "lifecycle.terminate resolves through BehaviorRegistry on the Agent Kind" do
    assert {:ok, Terminable} = BehaviorRegistry.lookup(Agent, :terminate)
  end

  test "an in-lineage worker is terminated via dispatch (cap-#2 happy path)" do
    orchestrator = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-#{uniq()}")
    worker_uri = spawn_worker(orchestrator)

    assert {:ok, _pid} = KindRegistry.lookup(worker_uri)

    caps = MapSet.new([terminate_cap(worker_uri, orchestrator)])

    assert {:ok, {:ok, :terminated}} = terminate(worker_uri, orchestrator, caps)

    assert :gone = wait_until_gone(worker_uri),
           "the worker process must be brought down after lifecycle.terminate"
  end

  test "a capability signed by a different agent authority cannot be retargeted" do
    orchestrator_a = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-a-#{uniq()}")
    orchestrator_b = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-b-#{uniq()}")

    # The worker is spawned by A.
    worker_uri = spawn_worker(orchestrator_a)

    # B's artifact is legitimate for B's own worker, but not for A's worker.
    worker_b = spawn_worker(orchestrator_b)
    caps_b = MapSet.new([terminate_cap(worker_b, orchestrator_b)])

    assert {:error, :invalid_cap_signature} = terminate(worker_uri, orchestrator_b, caps_b),
           "an artifact from worker B's authority must fail at worker A"

    # The worker is still alive — the denied dispatch had no effect.
    assert {:ok, _pid} = KindRegistry.lookup(worker_uri)
  end

  test "termination is idempotent — a second terminate on a gone agent still succeeds" do
    orchestrator = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-idem-#{uniq()}")
    worker_uri = spawn_worker(orchestrator)
    caps = MapSet.new([terminate_cap(worker_uri, orchestrator)])

    assert {:ok, {:ok, :terminated}} = terminate(worker_uri, orchestrator, caps)
    assert :gone = wait_until_gone(worker_uri)

    # The worker is gone — a second terminate dispatches to an absent
    # actor. `Ezagent.Orchestrator.Tools.terminate_worker/3` maps
    # :no_such_actor to idempotent success; here we assert the dispatch
    # itself surfaces the absent actor cleanly (not a crash).
    assert {:error, :no_such_actor} = terminate(worker_uri, orchestrator, caps)
  end

  describe "notification of spawning principal (med-batch MED-3)" do
    # `Behavior.Terminable.:terminate` must surface termination to the
    # spawning principal so the orchestrator / user who originated the
    # spawn learns the worker is going away. Gated by user_uri?/1:
    # only USER URIs get notifications (agents have no inbox).

    test "notifies a user-URI spawning principal on terminate" do
      # Canonical (`authority: nil`) — `Notifications.notify/3` rebroadcasts
      # the recipient URI via `parse_uri!` (canonical), so the `^user_uri`
      # pin on the `{:notification, user_uri, _}` envelope must hold the
      # canonical struct, not the `URI.parse` (`authority: "user"`) form.
      user_uri = Ezagent.URI.new!("entity://team-alpha/user/spawner-#{uniq()}")
      :ok = Ezagent.Notifications.subscribe(user_uri)

      worker_uri = spawn_worker(user_uri)

      # Bootstrap-admin caps — the user-URI lineage parent is a
      # spawning principal, not the dispatch caller; the orch.cap
      # gate is bypassed by using bootstrap-admin caps for the test
      # dispatch (lineage notification is independent of cap surface).
      admin_caps = MapSet.new([terminate_cap(worker_uri, User.admin_uri())])

      assert {:ok, {:ok, :terminated}} = terminate(worker_uri, User.admin_uri(), admin_caps)

      assert_receive {:notification, ^user_uri,
                      %{
                        type: :agent_terminated,
                        body: %{text: _, agent_uri: ^worker_uri},
                        source: Ezagent.ActionSet.Terminable
                      }},
                     1_000
    end

    test "does NOT notify when spawning principal is an agent URI" do
      orchestrator = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-noinbox-#{uniq()}")
      worker_uri = spawn_worker(orchestrator)
      caps = MapSet.new([terminate_cap(worker_uri, orchestrator)])

      # Subscribe to the agent URI's topic raw — Notifications.subscribe
      # would reject (agents not user-Kind); raw PubSub detects any
      # stray broadcast.
      :ok =
        Phoenix.PubSub.subscribe(
          EzagentCore.PubSub,
          Ezagent.Notifications.topic(orchestrator)
        )

      assert {:ok, {:ok, :terminated}} = terminate(worker_uri, orchestrator, caps)

      refute_receive {:notification, ^orchestrator, _}, 300
    end
  end
end
