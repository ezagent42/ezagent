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

    test "credential admission actions belong to the conversation dispatch family" do
      conversation_actions = Ezagent.World.DispatchContract.actions(:conversation)

      assert "session.agent_admission.begin" in conversation_actions
      assert "session.agent_admission.complete" in conversation_actions
      assert "session.agent_admission.cancel" in conversation_actions
    end
  end

  describe "credential admission session binding" do
    test "begin refuses a client request for a session other than the one on screen" do
      current = URI.new!("session://team-alpha/default/current-#{uniq()}")
      other = URI.new!("session://team-alpha/default/other-#{uniq()}")

      socket = socket_for() |> Phoenix.Component.assign(:current_session_uri, current)

      assert {:noreply, out} =
               dispatch(
                 "session.agent_admission.begin",
                 %{
                   "session_uri" => URI.to_string(other),
                   "role_name" => "llm",
                   "flavor" => "client-must-not-select-this",
                   "source_uri" => "entity://team-alpha/agent/forged"
                 },
                 socket
               )

      assert out.assigns.last_dispatch_status == "error:session_not_current"
    end
  end

  # #224 — three conversation handlers were dispatched by the React client but
  # were ABSENT from `DispatchContract.actions(:conversation)`, so they fell
  # through `WorldLive`'s guards to the catch-all and returned
  # `error:unsupported_action` — the handler never ran. Proof of ROUTING (not
  # of the handler's success): dispatch each with a MALFORMED `session_uri` but
  # otherwise-matching args. If it routes, its `with_session/3` guard rejects the
  # URI with the DISTINCT `error:bad_session_uri`; if it is still unrouted it
  # returns `error:unsupported_action` (the pre-fix behavior). The bad-URI probe
  # also sidesteps Blocker B (publish would still fail `template_write_cap?`,
  # #224 Fix-3, pending) — we prove reach, not publish.
  describe "#224 — conversation actions restored to the contract route to their handler" do
    test "session.publish_template routes (bad session_uri -> handler's bad_session_uri, not unsupported_action)" do
      assert {:noreply, out} =
               dispatch("session.publish_template", %{
                 "session_uri" => "not-a-session-uri",
                 "name" => "my-template"
               })

      assert out.assigns.last_dispatch_status == "error:bad_session_uri"
    end

    test "session.fork_config routes (bad session_uri -> handler's bad_session_uri, not unsupported_action)" do
      assert {:noreply, out} =
               dispatch("session.fork_config", %{"session_uri" => "not-a-session-uri"})

      assert out.assigns.last_dispatch_status == "error:bad_session_uri"
    end

    test "session.assign_role routes (bad session_uri -> handler's bad_session_uri, not unsupported_action)" do
      assert {:noreply, out} =
               dispatch("session.assign_role", %{
                 "session_uri" => "not-a-session-uri",
                 "member" => "entity://team-alpha/user/m",
                 "role_name" => "reviewer"
               })

      assert out.assigns.last_dispatch_status == "error:bad_session_uri"
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
