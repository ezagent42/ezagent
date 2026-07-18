defmodule Ezagent.DomainGit.CapFixtureTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Cap, Capability, Invocation}
  alias Ezagent.DomainGit.{RepositoryRef, TaskAccessSupervisor}
  alias Ezagent.DomainGit.TestSupport.GitCapFixture
  alias Ezagent.Entity.GitTaskAccess

  @action :create_change_request

  test "issues one signed receiver-bound exact task capability" do
    fixture = started_fixture(@action)

    assert Cap.storable_for?(fixture.artifact, fixture.grantee_uri)
    assert fixture.artifact.kind == :resource
    assert fixture.artifact.behavior == Ezagent.ActionSet.GitTaskAccess
    assert fixture.artifact.action == @action
    assert fixture.artifact.instance == Ezagent.URI.instance(fixture.task_access_uri)
    assert fixture.artifact.workspace_uri == fixture.workspace_uri
    assert fixture.artifact.grantee_uri == fixture.grantee_uri
    assert is_binary(fixture.artifact.signature)
    assert is_binary(fixture.artifact.key_id)

    assert %Invocation{
             ctx: %{caller: grantee_uri, caps: caps}
           } = fixture.invocation

    assert grantee_uri == fixture.grantee_uri
    assert caps == MapSet.new([fixture.artifact])
  end

  test "rejects the artifact for another receiver" do
    fixture = started_fixture(@action)
    wrong_grantee = Ezagent.URI.entity("git-fixture", "agent", "other-grantee")

    refute Cap.storable_for?(fixture.artifact, wrong_grantee)
  end

  test "rejects a different action, task instance, or workspace" do
    fixture = started_fixture(@action)

    wrong_action = required(fixture, :read_change_request)

    wrong_instance =
      required(fixture, @action,
        instance:
          Ezagent.URI.instance(
            Ezagent.URI.resource("git-fixture", "git-task-access", "other-task")
          )
      )

    wrong_workspace =
      required(fixture, @action, workspace_uri: Ezagent.URI.workspace("other-workspace"))

    refute Capability.matches?(fixture.artifact, wrong_action)
    refute Capability.matches?(fixture.artifact, wrong_instance)
    refute Capability.matches?(fixture.artifact, wrong_workspace)
  end

  test "fixture structurally issues artifacts and forbids raw or wildcard authority" do
    source =
      File.read!(Path.expand("../../support/git_cap_fixture.ex", __DIR__))

    assert source =~ "Capability.cap("
    assert source =~ "authorization = {:admin, admin_uri}"
    assert source =~ "Cap.issue(authorization, grantee_uri, capability)"
    assert source =~ "Cap.storable_for?(artifact, grantee_uri)"
    refute source =~ "%Capability{"
    refute source =~ ":any"
    refute source =~ "{:genesis,"

    fixture = started_fixture(@action)
    refute is_nil(fixture.artifact.signature)
    refute fixture.artifact.instance == :any
    refute fixture.artifact.workspace_uri == :any
  end

  test "safely configures unique workspace, task resource, grantee, and action coordinates" do
    suffix = System.unique_integer([:positive])
    workspace_name = "git-fixture-#{suffix}"
    task_access_id = "task-#{suffix}"
    action = :list_reviews
    grantee_uri = Ezagent.URI.entity(workspace_name, "agent", "worker-#{suffix}")

    fixture =
      started_fixture(action,
        workspace_name: workspace_name,
        task_access_id: task_access_id,
        grantee_uri: grantee_uri
      )

    expected_task_uri =
      Ezagent.URI.resource(workspace_name, "git-task-access", task_access_id)

    assert fixture.task_access_uri == expected_task_uri
    assert fixture.workspace_uri == Ezagent.URI.workspace(workspace_name)
    assert fixture.grantee_uri == grantee_uri
    assert fixture.artifact.action == action
    assert fixture.artifact.instance == Ezagent.URI.instance(expected_task_uri)
    assert Cap.storable_for?(fixture.artifact, grantee_uri)

    assert fixture.invocation.ctx == %{
             caller: grantee_uri,
             caps: MapSet.new([fixture.artifact]),
             reply: {:caller_inbox, self()}
           }
  end

  test "rejects unsafe fixture coordinate overrides" do
    other_workspace_grantee = Ezagent.URI.entity("other-workspace", "agent", "worker")

    assert_raise ArgumentError, fn ->
      GitCapFixture.coordinates(
        workspace_name: "git-fixture",
        grantee_uri: other_workspace_grantee
      )
    end

    assert_raise ArgumentError, fn ->
      GitCapFixture.coordinates(capability: Capability.admin_genesis_cap())
    end
  end

  defp required(fixture, action, overrides \\ []) do
    %{
      kind: :resource,
      behavior: Ezagent.ActionSet.GitTaskAccess,
      action: action,
      instance: Keyword.get(overrides, :instance, Ezagent.URI.instance(fixture.task_access_uri)),
      workspace_uri: Keyword.get(overrides, :workspace_uri, fixture.workspace_uri)
    }
  end

  defp started_fixture(action, options \\ []) do
    coordinates = GitCapFixture.coordinates(options)
    workspace = Ezagent.URI.workspace_name!(coordinates.workspace_uri)

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", "fixture-repo"),
        provider_adapter: :fixture_git,
        provider_host: "git.example.test",
        external_id: "fixture-repo",
        owner_path: "fixture/repo",
        base_ref: "main",
        visibility: :private
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: coordinates.task_access_uri.path |> String.split("/") |> List.last(),
        task_id: "fixture-task",
        generation: 1,
        workspace_uri: coordinates.workspace_uri,
        credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
        grantee_uri: coordinates.grantee_uri,
        repository: repository,
        provider_adapter: :fixture_git,
        allowed_head_ref: "task/fixture",
        allowed_actions: [@action, :list_reviews],
        idempotency_inputs: %{task_id: "fixture-task", generation: 1}
      })

    assert {:ok, _pid} = TaskAccessSupervisor.ensure_started(policy)
    on_exit(fn -> TaskAccessSupervisor.teardown(coordinates.task_access_uri) end)
    GitCapFixture.exact_task_cap(coordinates, action)
  end
end
