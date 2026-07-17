defmodule Ezagent.Workspace.TaskWorkspace.LaunchAuthorityTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Agent.LaunchAuthority, as: Port
  alias Ezagent.Workspace.TaskWorkspace.{LaunchAuthority, Provision, Store}

  setup do
    :ok = Port.register(LaunchAuthority)
  end

  test "issue resolves exact durable identity and acknowledgement consumes it once" do
    starting = starting_row()
    handle = LaunchAuthority.issue(starting.id, starting.start_claim_token)

    assert is_reference(handle)

    assert {:ok,
            %{
              attempt_id: attempt,
              agent_uri: agent,
              root_uri: root,
              workspace_uri: workspace,
              issuer_ref: {^handle, claim}
            }} = Port.resolve(handle, agent_uri())

    assert attempt == starting.creation_attempt_id
    assert agent == agent_uri()
    assert root == root_uri()
    assert workspace == workspace_uri()
    assert claim == starting.start_claim_token

    assert :ok = Port.acknowledge({handle, claim})
    assert {:error, :launch_context_consumed} = Port.resolve(handle, agent_uri())
    assert {:error, :launch_context_consumed} = Port.acknowledge({handle, claim})
  end

  test "wrong URI and forged references fail without identity values" do
    starting = starting_row()
    handle = LaunchAuthority.issue(starting.id, starting.start_claim_token)

    assert_identity_free(
      {:error, :launch_agent_uri_mismatch},
      Port.resolve(handle, Ezagent.URI.agent("launch-authority", "other")),
      starting
    )

    assert_identity_free(
      {:error, :invalid_launch_context},
      Port.resolve(make_ref(), agent_uri()),
      starting
    )
  end

  test "empty or malformed durable identity fails closed" do
    starting = starting_row()
    handle = LaunchAuthority.issue(starting.id, starting.start_claim_token)

    corruptions = [
      [creation_attempt_id: ""],
      [agent_uri: "not-a-uri"],
      [provenance_root_uri: ""],
      [workspace_uri: "not-a-uri"]
    ]

    for changes <- corruptions do
      EzagentCore.Repo.update_all(
        from(p in Provision, where: p.id == ^starting.id),
        set: changes
      )

      assert_identity_free(
        {:error, :invalid_launch_identity},
        Port.resolve(handle, agent_uri()),
        starting
      )

      restore_identity(starting)
    end
  end

  test "expired and replaced claims fence previously issued handles" do
    starting = starting_row(lease_seconds: 1)
    expired_handle = LaunchAuthority.issue(starting.id, starting.start_claim_token)
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    EzagentCore.Repo.update_all(
      from(p in Provision, where: p.id == ^starting.id),
      set: [start_lease_until: expired_at]
    )

    assert_identity_free(
      {:error, :launch_claim_expired},
      Port.resolve(expired_handle, agent_uri()),
      starting
    )

    takeover_at = DateTime.add(starting.start_lease_until, 1, :second)

    {:ok, replacement} =
      Store.claim_start(starting.id, starting.start_token, now: takeover_at, lease_seconds: 60)

    replaced_handle = LaunchAuthority.issue(replacement.id, starting.start_claim_token)

    assert_identity_free(
      {:error, :launch_claim_replaced},
      Port.resolve(replaced_handle, agent_uri()),
      starting
    )
  end

  test "caller DOWN does not revoke an issued handle" do
    starting = starting_row()
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        handle = LaunchAuthority.issue(starting.id, starting.start_claim_token)
        send(parent, {:issued, self(), handle})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:issued, ^caller, handle}
    send(caller, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert {:ok, %{agent_uri: agent}} = Port.resolve(handle, agent_uri())
    assert agent == agent_uri()
  end

  defp assert_identity_free(expected, actual, starting) do
    assert actual == expected
    inspected = inspect(actual)
    refute inspected =~ starting.creation_attempt_id
    refute inspected =~ starting.agent_uri
    refute inspected =~ starting.provenance_root_uri
    refute inspected =~ starting.workspace_uri
  end

  defp restore_identity(starting) do
    EzagentCore.Repo.update_all(
      from(p in Provision, where: p.id == ^starting.id),
      set: [
        creation_attempt_id: starting.creation_attempt_id,
        agent_uri: starting.agent_uri,
        provenance_root_uri: starting.provenance_root_uri,
        workspace_uri: starting.workspace_uri
      ]
    )
  end

  defp starting_row(opts \\ []) do
    suffix = System.unique_integer([:positive])
    {:ok, planned} = Store.create_planned(attrs(suffix))
    {:ok, provisioning} = Store.claim_provision(planned.id, lease_seconds: 60)

    {:ok, ready} =
      Store.mark_ready(planned.id, provisioning.claim_token, %{
        expected_version: provisioning.state_version,
        cache_identity: "cache-#{suffix}",
        worktree_identity: "worktree-#{suffix}",
        worktree_path: "/tmp/launch-authority-#{suffix}",
        resolved_base_commit: String.duplicate("a", 40),
        local_branch_ref: Ezagent.Workspace.TaskWorkspace.GitRunner.local_branch_ref(provisioning)
      })

    {:ok, bound} =
      Store.bind_start_intent(ready.provision_id, %{
        agent_uri: URI.to_string(agent_uri()),
        provenance_root_uri: URI.to_string(root_uri()),
        workspace_uri: URI.to_string(workspace_uri()),
        task_access_uri: ready.task_access_uri,
        task_uri: ready.task_uri,
        generation: ready.generation
      })

    {:ok, starting} =
      Store.claim_start(bound.id, bound.start_token,
        lease_seconds: Keyword.get(opts, :lease_seconds, 60)
      )

    starting
  end

  defp attrs(suffix) do
    %{
      provision_id: "launch-authority-#{suffix}",
      workspace_uri: URI.to_string(workspace_uri()),
      task_uri: "resource://launch-authority/kanban-task/task-#{suffix}",
      generation: 1,
      task_access_uri: "resource://launch-authority/git-task-access/access-#{suffix}",
      repository_uri: "resource://launch-authority/git-repository/repo-#{suffix}",
      checkout_fingerprint: "checkout-#{suffix}",
      base_ref: "main",
      allowed_head_ref: "task/#{suffix}",
      visibility: :public
    }
  end

  defp agent_uri, do: Ezagent.URI.agent("launch-authority", "worker")
  defp root_uri, do: Ezagent.URI.user("launch-authority", "owner")
  defp workspace_uri, do: Ezagent.URI.workspace("launch-authority")
end
