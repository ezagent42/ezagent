defmodule EzagentCli.Integration.CLIDispatchTest do
  use EzagentCore.DataCase, async: false

  alias EzagentCli.{Dispatch, TreeBuilder}

  setup do
    # Sandbox provided by EzagentCore.DataCase (#92).

    # Codex CLI/GUI audit 2026-05-24 HIGH-1: Dispatch.derive_caller/1
    # no longer silently falls back to admin. Tests must set the same
    # per-process caller override that `EzagentCli.Exec.exec/2` sets
    # in production after token authentication.
    Process.put(
      :ezagent_cli_caller_override,
      {Ezagent.Entity.User.admin_uri(), MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
    )

    :ok
  end

  describe "Dispatch.run_action — end-to-end via auto-derive" do
    test "workspace list_members on an existing workspace returns the member list" do
      name = "cli-test-#{System.unique_integer([:positive])}"

      members = [
        Ezagent.URI.new!("entity://system/user/admin"),
        Ezagent.URI.new!("entity://team-alpha/agent/test_test-cli")
      ]

      {:ok, _pid} = Ezagent.Workspace.create(name, %{members: members})

      parsed = %{
        options: %{workspace: name},
        flags: %{cast: false, json: false}
      }

      assert {:ok, %{members: returned}} =
               Dispatch.run_action(
                 Ezagent.Entity.Workspace,
                 Ezagent.ActionSet.Workspace,
                 :list_members,
                 parsed
               )

      assert length(returned) == 2
    end

    test "workspace add_member persists + dispatches" do
      name = "cli-add-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Ezagent.Workspace.create(name)

      # Task #55 (PR #417) — add_member now enforces a workspace-prefix
      # invariant: the member URI MUST live in the same workspace as
      # the target workspace Kind. Earlier this test used a fixed
      # `entity://team-alpha/agent/...` URI which would now be rejected
      # (`team-alpha` != the random `cli-add-N` workspace). Build the
      # member URI in `name` so add_member's validator passes.
      member_uri = Ezagent.URI.new!("entity://#{name}/agent/test_cli-new-member")

      parsed = %{
        options: %{workspace: name, member: member_uri},
        flags: %{cast: true, json: false}
      }

      assert {:ok, _} =
               Dispatch.run_action(
                 Ezagent.Entity.Workspace,
                 Ezagent.ActionSet.Workspace,
                 :add_member,
                 parsed
               )

      # Wait for cast to land
      Process.sleep(50)

      # Verify via list_members
      target = Ezagent.URI.new!("workspace://#{name}?action=workspace.list_members")
      admin = Ezagent.Entity.User.admin_uri()
      {:ok, list_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

      assert {:ok, %{members: members}} =
               Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                 origin: :trusted_internal,
                 target: target,
                 mode: :call,
                 args: %{},
                 # #195 threads the authenticated principal as the cap HOLDER:
                 # `Ezagent.Cap.Verifier.authorize/6` reads `ctx.authenticated_principal`
                 # and fails closed with `:authenticated_principal_required` when it
                 # is absent. A hand-built invocation must carry it (production
                 # dispatch paths — CLI Exec, LV, the session-config admission gate —
                 # all set it); `admin` holds the presented `list_cap`.
                 ctx: %{
                   caller: admin,
                   authenticated_principal: admin,
                   caps: MapSet.new([list_cap]),
                   reply: {:caller_inbox, self()}
                 }
               })

      assert Enum.any?(members, fn u -> URI.to_string(u) == URI.to_string(member_uri) end)
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
      expected = Ezagent.ActionSet.Workspace.interface()[:add_member][:description]
      assert is_binary(expected)
      assert add_member.about == expected
      refute add_member.about == "add_member action on #{Ezagent.ActionSet.Workspace}"
    end

    test "workspace subcommand includes :create facade op (registered by EzagentCore.Application)" do
      # Ensure registration ran by booting ezagent_core
      Application.ensure_all_started(:ezagent_core)
      Application.ensure_all_started(:ezagent_cli)

      spec = TreeBuilder.build()
      ws_sub = Enum.find(spec.subcommands, fn s -> s.name == "workspace" end)
      assert ws_sub

      action_names = ws_sub.subcommands |> Enum.map(& &1.name) |> MapSet.new()

      assert MapSet.member?(action_names, "create"),
             "create facade op missing from workspace subcommands"
    end
  end
end
