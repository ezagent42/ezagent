defmodule Ezagent.Agent.LaunchCoordinatorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.{CreationInventory, LaunchAuthority, LaunchCoordinator}
  alias EzagentCore.Repo

  defmodule Authority do
    @behaviour Ezagent.Agent.LaunchAuthority

    @impl true
    def resolve_launch(handle, agent_uri) do
      case :persistent_term.get({__MODULE__, handle}, :missing) do
        %{agent_uri: ^agent_uri} = facts -> {:ok, facts}
        :missing -> {:error, :unknown_launch}
        _facts -> {:error, :agent_uri_mismatch}
      end
    end

    @impl true
    def acknowledge_launch(issuer_ref) do
      owner = :persistent_term.get({__MODULE__, :owner})

      case :persistent_term.get({__MODULE__, :ack_result}, :ok) do
        :block ->
          send(owner, {:acknowledged, issuer_ref, self()})

          receive do
            :release_acknowledgement -> :ok
          end

        result ->
          send(owner, {:acknowledged, issuer_ref})
          result
      end
    end
  end

  setup do
    registered = :sys.get_state(LaunchAuthority)
    :sys.replace_state(LaunchAuthority, fn _ -> Authority end)
    :persistent_term.put({Authority, :owner}, self())
    :persistent_term.put({Authority, :ack_result}, :ok)

    on_exit(fn ->
      :persistent_term.erase({Authority, :owner})
      :persistent_term.erase({Authority, :ack_result})
      :sys.replace_state(LaunchAuthority, fn _ -> registered end)
    end)

    :ok
  end

  test "commits the exact inventory and lineage before publishing caches and acknowledges" do
    facts = facts()
    handle = issue(facts)
    issuer_ref = facts.issuer_ref

    assert {:ok, receipt} = LaunchCoordinator.consume_before_start(facts.agent_uri, handle)
    assert receipt.attempt_id == facts.attempt_id
    assert_receive {:acknowledged, ^issuer_ref}

    assert {:ok, _entry} =
             CreationInventory.exact(
               facts.attempt_id,
               facts.agent_uri,
               facts.root_uri,
               facts.workspace_uri
             )

    assert %Ezagent.AgentLineage{spawned_by: parent} =
             Repo.get(Ezagent.AgentLineage, URI.to_string(facts.agent_uri))

    assert parent == URI.to_string(facts.root_uri)
    assert {:ok, facts.root_uri} == Ezagent.AgentLineage.lookup(facts.agent_uri)
    assert {:ok, facts.workspace_uri} == Ezagent.WorkspaceRegistry.lookup(facts.agent_uri)
  end

  test "exact replay succeeds when post-commit acknowledgement fails" do
    facts = facts()
    handle = issue(facts)
    :persistent_term.put({Authority, :ack_result}, {:error, :injected_ack_failure})

    assert {:ok, first} = LaunchCoordinator.consume_before_start(facts.agent_uri, handle)
    assert {:ok, ^first} = LaunchCoordinator.consume_before_start(facts.agent_uri, handle)
  end

  test "durable facts precede actor visibility and survive the spawning caller" do
    facts = facts()
    handle = issue(facts)
    :persistent_term.put({Authority, :ack_result}, :block)

    caller =
      spawn(fn ->
        Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: facts.agent_uri}, launch_context: handle)
      end)

    assert_receive {:acknowledged, issuer_ref, authority_pid}
    assert issuer_ref == facts.issuer_ref

    assert {:ok, _entry} =
             CreationInventory.exact(
               facts.attempt_id,
               facts.agent_uri,
               facts.root_uri,
               facts.workspace_uri
             )

    assert %Ezagent.AgentLineage{} =
             Repo.get(Ezagent.AgentLineage, URI.to_string(facts.agent_uri))

    assert :error = Ezagent.KindRegistry.lookup(facts.agent_uri)
    assert :unknown = Ezagent.ReadyGate.status(URI.to_string(facts.agent_uri))
    assert nil == Ezagent.Ecto.KindSnapshot.get(URI.to_string(facts.agent_uri))

    Process.exit(caller, :kill)
    send(authority_pid, :release_acknowledgement)

    assert {:ok, _entry} =
             CreationInventory.exact(
               facts.attempt_id,
               facts.agent_uri,
               facts.root_uri,
               facts.workspace_uri
             )

    assert %Ezagent.AgentLineage{} =
             Repo.get(Ezagent.AgentLineage, URI.to_string(facts.agent_uri))

    assert :ok = Ezagent.ReadyGate.await(URI.to_string(facts.agent_uri), 1_000)
    assert {:ok, child} = Ezagent.KindRegistry.lookup(facts.agent_uri)
    :ok = DynamicSupervisor.terminate_child(Ezagent.Entity.Agent.supervisor(), child)
  end

  test "lineage conflict rolls inventory back and publishes no binding" do
    facts = facts()
    conflicting_root = Ezagent.URI.new!("entity://team-alpha/user/conflict-#{uniq()}")

    assert {:ok, :inserted} =
             Ezagent.AgentLineage.record_exact(Repo, facts.agent_uri, conflicting_root)

    assert {:error, :lineage_conflict} =
             LaunchCoordinator.consume_before_start(facts.agent_uri, issue(facts))

    assert {:error, :creation_attempt_not_found} =
             CreationInventory.exact(
               facts.attempt_id,
               facts.agent_uri,
               facts.root_uri,
               facts.workspace_uri
             )

    assert :error = Ezagent.AgentLineage.lookup(facts.agent_uri)
    assert :error = Ezagent.WorkspaceRegistry.lookup(facts.agent_uri)
    refute_receive {:acknowledged, _}
  end

  test "inventory conflict does not write lineage or publish caches" do
    facts = facts()
    other_root = Ezagent.URI.new!("entity://team-alpha/user/other-#{uniq()}")

    assert {:ok, :inserted} =
             CreationInventory.record_exact(
               Repo,
               facts.attempt_id,
               facts.agent_uri,
               other_root,
               facts.workspace_uri
             )

    assert {:error, :creation_fact_conflict} =
             LaunchCoordinator.consume_before_start(facts.agent_uri, issue(facts))

    assert nil == Repo.get(Ezagent.AgentLineage, URI.to_string(facts.agent_uri))
    assert :error = Ezagent.AgentLineage.lookup(facts.agent_uri)
    assert :error = Ezagent.WorkspaceRegistry.lookup(facts.agent_uri)
  end

  test "rejects non-Agent targets, workspace mismatch, cross-workspace root, and empty attempts" do
    valid = facts()

    invalid = [
      {%{valid | agent_uri: Ezagent.URI.new!("entity://team-alpha/user/not-agent")},
       :invalid_agent_type},
      {%{valid | workspace_uri: Ezagent.URI.new!("workspace://team-beta")}, :workspace_mismatch},
      {%{valid | root_uri: Ezagent.URI.new!("entity://team-beta/user/root")},
       :root_workspace_mismatch},
      {%{valid | attempt_id: ""}, :invalid_attempt_id}
    ]

    for {facts, error} <- invalid do
      assert {:error, ^error} =
               LaunchCoordinator.consume_before_start(facts.agent_uri, issue(facts))
    end
  end

  defp facts do
    id = uniq()

    %{
      attempt_id: "attempt-#{id}",
      agent_uri: Ezagent.URI.new!("entity://team-alpha/agent/launch-#{id}"),
      root_uri: Ezagent.URI.new!("entity://team-alpha/user/root-#{id}"),
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      issuer_ref: {make_ref(), "claim-#{id}"}
    }
  end

  defp issue(facts) do
    handle = make_ref()
    :persistent_term.put({Authority, handle}, facts)
    on_exit(fn -> :persistent_term.erase({Authority, handle}) end)
    handle
  end

  defp uniq, do: System.unique_integer([:positive])
end
