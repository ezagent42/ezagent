defmodule Ezagent.DomainGit.CapFixtureTest do
  use ExUnit.Case, async: true

  alias Ezagent.{Cap, Capability, Invocation}
  alias Ezagent.DomainGit.TestSupport.GitCapFixture

  @action :create_change_request

  test "issues one signed receiver-bound exact task capability" do
    fixture = GitCapFixture.exact_task_cap(@action)

    assert Cap.verify_for(fixture.artifact, fixture.grantee_uri)
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
    fixture = GitCapFixture.exact_task_cap(@action)
    wrong_grantee = Ezagent.URI.entity("git-fixture", "agent", "other-grantee")

    refute Cap.verify_for(fixture.artifact, wrong_grantee)
  end

  test "rejects a different action, task instance, or workspace" do
    fixture = GitCapFixture.exact_task_cap(@action)

    wrong_action = required(fixture, :read_change_request)

    wrong_instance =
      required(fixture, @action,
        instance: Ezagent.URI.resource("git-fixture", "git-task-access", "other-task")
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
    assert source =~ "Cap.issue(authorization, grantee_uri, capability)"
    assert source =~ "Cap.verify_for(artifact, grantee_uri)"
    refute source =~ "%Capability{"
    refute source =~ ":any"

    fixture = GitCapFixture.exact_task_cap(@action)
    refute is_nil(fixture.artifact.signature)
    refute fixture.artifact.instance == :any
    refute fixture.artifact.workspace_uri == :any
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
end
