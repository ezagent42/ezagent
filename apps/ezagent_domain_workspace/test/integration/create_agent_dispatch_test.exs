defmodule Ezagent.Integration.CreateAgentDispatchTest do
  @moduledoc """
  Acceptance test for SPEC 2026-05-25-agent-create-cli-gui-parity:
  the unified `Ezagent.Workspace.create_agent/3` facade — what BOTH
  the CLI (`mix ezagent.agent.create`) and the LV
  (`EzagentPluginLiveview.AgentNewLive`) call — dispatches the
  `Behavior.Workspace.:create_agent` action.

  Focused on the action's contract surface (validation + early-exit
  shapes) without needing real plugin Template Classes. The full
  spawn-via-Template chain is exercised by:

  - `add_template_invokes_test.exs` — the Loader.invoke_template
    chain that the action body delegates to.
  - Plugin-side integration tests (`ezagent_plugin_cc/test/...`) —
    cc/echo Template Class instantiate behaviour.

  This test verifies the unification's WIRING: the dispatched action
  routes through `Behavior.Workspace.:create_agent` and returns the
  shapes the CLI + LV both consume.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User

  setup do
    ws_name = "create-agent-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")
    admin_ctx = %{caller: User.admin_uri(), caps: User.admin_caps()}

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "Ezagent.Workspace.create_agent/3 — validation + dispatch wiring" do
    test "empty flavor returns {:error, :flavor_required}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, :flavor_required} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "", name: "x", cwd: "", with_pty: false},
                 admin_ctx
               )
    end

    test "empty name returns {:error, :name_required}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, :name_required} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: "", cwd: "", with_pty: false},
                 admin_ctx
               )
    end

    test "bad flavor returns {:error, {:bad_flavor, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_flavor, "definitely-not-a-flavor"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "definitely-not-a-flavor",
                   name: "x",
                   cwd: "",
                   with_pty: false
                 },
                 admin_ctx
               )
    end

    test "bad name returns {:error, {:bad_name, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_name, "invalid name with space"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "curl",
                   name: "invalid name with space",
                   cwd: "",
                   with_pty: false
                 },
                 admin_ctx
               )
    end

    test "cc flavor missing cwd returns {:error, :cwd_required_for_cc}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, :cwd_required_for_cc} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "cc", name: "demo", cwd: "", with_pty: false},
                 admin_ctx
               )
    end

    test "echo+with_pty missing cwd returns {:error, :cwd_required_for_echo_with_pty}",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      assert {:error, :cwd_required_for_echo_with_pty} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "echo", name: "shell", cwd: "", with_pty: true},
                 admin_ctx
               )
    end

    test "cc flavor nonexistent cwd returns {:error, {:cwd_not_a_dir, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:cwd_not_a_dir, "/this/path/definitely/does/not/exist/anywhere"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "demo",
                   cwd: "/this/path/definitely/does/not/exist/anywhere",
                   with_pty: false
                 },
                 admin_ctx
               )
    end
  end

  describe "Ezagent.Workspace.grant_initial_caps/3 — empty list short-circuit" do
    test "empty cap list returns :ok without dispatching", %{admin_ctx: admin_ctx} do
      # No agent URI needed — empty list never touches dispatch.
      fake_uri = URI.parse("entity://agent/system/cc_fake")
      assert :ok = Workspace.grant_initial_caps(fake_uri, [], admin_ctx)
    end
  end
end
