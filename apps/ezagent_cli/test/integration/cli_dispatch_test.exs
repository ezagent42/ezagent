defmodule EzagentCli.Integration.CLIDispatchTest do
  use ExUnit.Case, async: false

  alias EzagentCli.{Dispatch, TreeBuilder}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  describe "Dispatch.run_action — end-to-end via auto-derive" do
    test "workspace list_members on an existing workspace returns the member list" do
      name = "cli-test-#{System.unique_integer([:positive])}"
      members = [URI.parse("entity://user/system/admin"), URI.parse("entity://agent/default/test_test-cli")]
      {:ok, _pid} = Ezagent.Workspace.create(name, %{members: members})

      parsed = %{
        options: %{workspace: name},
        flags: %{cast: false, json: false}
      }

      assert {:ok, %{members: returned}} =
               Dispatch.run_action(
                 Ezagent.Entity.Workspace,
                 Ezagent.Behavior.Workspace,
                 :list_members,
                 parsed
               )

      assert length(returned) == 2
    end

    test "workspace add_member persists + dispatches" do
      name = "cli-add-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name)

      parsed = %{
        options: %{workspace: name, member: URI.parse("entity://agent/default/test_cli-new-member")},
        flags: %{cast: true, json: false}
      }

      assert {:ok, _} =
               Dispatch.run_action(
                 Ezagent.Entity.Workspace,
                 Ezagent.Behavior.Workspace,
                 :add_member,
                 parsed
               )

      # Wait for cast to land
      Process.sleep(50)

      # Verify via list_members
      target = URI.parse("workspace://#{name}?action=workspace.list_members")

      assert {:ok, %{members: members}} =
               Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                 target: target,
                 mode: :call,
                 args: %{},
                 ctx: %{
                   caller: Ezagent.Entity.User.admin_uri(),
                   caps: Ezagent.Entity.User.admin_caps(),
                   reply: {:caller_inbox, self()}
                 }
               })

      assert Enum.any?(members, fn u ->
               URI.to_string(u) == "entity://agent/default/test_cli-new-member"
             end)
    end
  end

  describe "TreeBuilder.build/1 — auto-derive shape" do
    test "produces a subcommand for every Kind in BehaviorRegistry" do
      spec = TreeBuilder.build()
      sub_names = spec.subcommands |> Enum.map(& &1.name) |> MapSet.new()

      # At minimum: workspace, user, agent, session must be there (echo too)
      assert MapSet.member?(sub_names, "workspace")
      assert MapSet.member?(sub_names, "user")
      assert MapSet.member?(sub_names, "session")
      assert MapSet.member?(sub_names, "agent")
    end

    test "workspace subcommand contains add_member action" do
      spec = TreeBuilder.build()
      ws_sub = Enum.find(spec.subcommands, fn s -> s.name == "workspace" end)
      assert ws_sub

      action_names = ws_sub.subcommands |> Enum.map(& &1.name) |> MapSet.new()
      assert MapSet.member?(action_names, "add_member")
      assert MapSet.member?(action_names, "list_members")
      assert MapSet.member?(action_names, "instantiate")
    end

    test "action `about` text comes from the @interface :description key (V1 UI SPEC §0)" do
      spec = TreeBuilder.build()
      ws_sub = Enum.find(spec.subcommands, fn s -> s.name == "workspace" end)
      assert ws_sub

      add_member = Enum.find(ws_sub.subcommands, fn s -> s.name == "add_member" end)
      assert add_member

      # tree_builder.action_about/2 reads interface[action][:description]
      # directly — no Code.fetch_docs scrape, no generic fallback.
      expected = Ezagent.Behavior.Workspace.interface()[:add_member][:description]
      assert is_binary(expected)
      assert add_member.about == expected
      refute add_member.about == "add_member action on #{Ezagent.Behavior.Workspace}"
    end

    test "workspace subcommand includes :create facade op (registered by EzagentCore.Application)" do
      # Ensure registration ran by booting ezagent_core
      Application.ensure_all_started(:ezagent_core)
      Application.ensure_all_started(:ezagent_cli)

      spec = TreeBuilder.build()
      ws_sub = Enum.find(spec.subcommands, fn s -> s.name == "workspace" end)
      assert ws_sub

      action_names = ws_sub.subcommands |> Enum.map(& &1.name) |> MapSet.new()
      assert MapSet.member?(action_names, "create"), "create facade op missing from workspace subcommands"
    end
  end
end
