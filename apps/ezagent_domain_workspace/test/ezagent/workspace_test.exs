defmodule Ezagent.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Ezagent.Entity.Workspace, as: WK
  alias Ezagent.{Invocation, KindRegistry}

  setup do
    # Spawn workspaces under unique names so async tests don't collide.
    # async: false at module level guarantees serial execution within this
    # file (other test files can still run concurrently).
    :ok
  end

  describe "spawn_workspace/2" do
    test "starts a Kind and registers workspace://<name>" do
      name = "spawn-test-#{System.unique_integer([:positive])}"
      uri = WK.uri_for(name)

      assert {:ok, pid} = Ezagent.Workspace.spawn_workspace(name)
      assert is_pid(pid)
      assert {:ok, ^pid} = KindRegistry.lookup(uri)
    end

    test "second spawn at same URI returns {:error, {:already_started, pid}}" do
      name = "dup-test-#{System.unique_integer([:positive])}"

      {:ok, pid1} = Ezagent.Workspace.spawn_workspace(name)
      assert {:error, {:already_started, ^pid1}} = Ezagent.Workspace.spawn_workspace(name)
    end

    test "members in initial args are reachable via :list_members dispatch" do
      name = "members-test-#{System.unique_integer([:positive])}"
      uri = WK.uri_for(name)
      members = [URI.parse("entity://user/system/admin"), URI.parse("entity://agent/team-alpha/test_x")]

      {:ok, _pid} = Ezagent.Workspace.spawn_workspace(name, %{members: members})

      target = URI.parse("#{URI.to_string(uri)}?action=workspace.list_members")

      assert {:ok, %{members: listed}} =
               Invocation.dispatch(%Invocation{
                 target: target,
                 mode: :call,
                 args: %{},
                 ctx: %{
                   caller: Ezagent.Entity.User.admin_uri(),
                   caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                   reply: {:caller_inbox, self()}
                 }
               })

      assert length(listed) == 2
    end
  end

  describe "instantiate via dispatch" do
    test ":instantiate returns one child per member" do
      name = "inst-test-#{System.unique_integer([:positive])}"
      uri = WK.uri_for(name)
      members = [URI.parse("entity://user/system/admin"), URI.parse("entity://agent/team-alpha/test_cc-builder")]

      {:ok, _pid} = Ezagent.Workspace.spawn_workspace(name, %{members: members})

      target = URI.parse("#{URI.to_string(uri)}?action=workspace.instantiate")

      assert {:ok, %{children: children}} =
               Invocation.dispatch(%Invocation{
                 target: target,
                 mode: :call,
                 args: %{},
                 ctx: %{
                   caller: Ezagent.Entity.User.admin_uri(),
                   caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                   reply: {:caller_inbox, self()}
                 }
               })

      assert length(children) == 2
      assert Enum.all?(children, fn {:member, %URI{}} -> true end)
    end
  end

  describe "list_workspaces/0" do
    test "returns URIs for every live workspace://" do
      name1 = "list-a-#{System.unique_integer([:positive])}"
      name2 = "list-b-#{System.unique_integer([:positive])}"

      {:ok, _} = Ezagent.Workspace.spawn_workspace(name1)
      {:ok, _} = Ezagent.Workspace.spawn_workspace(name2)

      uris = Ezagent.Workspace.list_workspaces() |> Enum.map(&URI.to_string/1)

      assert "workspace://#{name1}" in uris
      assert "workspace://#{name2}" in uris
    end
  end
end
