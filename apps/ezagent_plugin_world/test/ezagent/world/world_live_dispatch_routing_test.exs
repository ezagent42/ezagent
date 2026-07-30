defmodule Ezagent.World.WorldLiveDispatchRoutingTest do
  @moduledoc """
  P2 test-supplement — `EzagentPluginWorld.WorldLive`'s `"world:dispatch"`
  ROUTING table (13.97% covered before this file) had no direct test: every
  `Ezagent.World.DispatchContract.actions/1` group is matched by a dedicated
  `handle_event` clause that wraps the target Actions module's
  `handle_dispatch/3` in `with_admin_operator/2`, but nothing exercised those
  clauses directly — only the target modules' OWN dispatch entry points (via
  their individual test files).

  This drives the REAL public LiveView event handler for one action per
  category (`agent`, `user`, `admin`, `cmdk`, `workspace_plugin`, `market`,
  `conversation`), each with args that don't match that module's specific
  clause — so every case lands on the target module's uniform
  `error:unsupported_action` catch-all. Two things are pinned at once:

    * **routing correctness** — the action string reaches the RIGHT Actions
      module (a misrouted action would land on a DIFFERENT module's
      catch-all, which still degrades safely, but a routing bug that instead
      raised would be caught here).
    * **priority #3 (hostile/malformed input, no crash-500s)** — malformed
      `args` on every dispatch category degrade to a clean `error:` status,
      never an exception, across the FULL breadth of world's public dispatch
      surface (not just `sessions.join`, already covered in
      `malformed_session_input_test.exs`).

  Also pins the two direct (non-grouped) clauses this table has always had:
  an unrecognized top-level action, and the `pty_resize` no-op.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginWorld.WorldLive

  defp uniq, do: System.unique_integer([:positive])

  defp socket_for(caller \\ nil) do
    caller = caller || URI.new!("entity://team-alpha/user/router-probe-#{uniq()}")

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:current_entity_uri, caller)
    |> Phoenix.Component.assign(:current_workspace_uri, URI.new!("workspace://team-alpha"))
    |> Phoenix.Component.assign(:world_state, %{"layout" => %{}})
    |> Phoenix.Component.assign(:world_state_json, "{}")
    |> Phoenix.Component.assign(:last_dispatch_status, "idle")
  end

  defp dispatch(action, args, socket \\ socket_for()) do
    WorldLive.handle_event("world:dispatch", %{"action" => action, "args" => args}, socket)
  end

  describe "each dispatch category routes to its Actions module (malformed args -> clean denial)" do
    test "agent group (agents.create, missing the \"agent\" key)" do
      assert {:noreply, out} = dispatch("agents.create", %{})
      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end

    test "user group (users.create, missing the \"user\" key)" do
      assert {:noreply, out} = dispatch("users.create", %{})
      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end

    test "admin group (admin.registration.save, missing the \"registration\" key)" do
      assert {:noreply, out} = dispatch("admin.registration.save", %{})
      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end

    test "cmdk group (cmdk.select, missing the \"key\" key)" do
      assert {:noreply, out} = dispatch("cmdk.select", %{})
      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end

    test "workspace_plugin group (workspace.member.remove, missing \"member_uri\")" do
      assert {:noreply, out} = dispatch("workspace.member.remove", %{})
      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end

    test "market group (market.publish, missing the binary \"name\" key)" do
      assert {:noreply, out} = dispatch("market.publish", %{})
      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end

    test "conversation group (chat.send, missing \"session_uri\"/\"text\")" do
      assert {:noreply, out} = dispatch("chat.send", %{})
      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end
  end

  describe "direct (non-grouped) clauses" do
    test "an unrecognized top-level action degrades to error:unsupported_action" do
      assert {:noreply, out} = dispatch("totally.made.up.action", %{"x" => 1})
      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end

    test "world:dispatch with no recognizable params at all does not crash" do
      assert {:noreply, out} =
               WorldLive.handle_event("world:dispatch", %{}, socket_for())

      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end

    test "pty_resize is a pure no-op (never crashes on arbitrary params)" do
      assert {:noreply, _out} =
               WorldLive.handle_event("pty_resize", %{"cols" => 80, "rows" => 24}, socket_for())
    end

    test "pty_input off the pty route degrades cleanly" do
      socket = socket_for() |> Phoenix.Component.assign(:world_state, %{})

      assert {:noreply, out} =
               WorldLive.handle_event("pty_input", %{"bytes" => "ls\n"}, socket)

      assert out.assigns.last_dispatch_status == "error:not_pty_route"
    end
  end

  describe "world:navigate" do
    test "an unrecognized navigation target is a safe no-op" do
      assert {:noreply, _out} =
               WorldLive.handle_event(
                 "world:navigate",
                 %{"to" => "not-a-real-nav-target-#{uniq()}"},
                 socket_for()
               )
    end
  end
end
