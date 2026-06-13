defmodule EzagentPluginLiveview.AdminLiveWorkspaceGateTest do
  @moduledoc """
  Task #55 round-2 codex CRIT-2 — workspace gate on /sessions deep-link.

  Pre-fix: `admin_live.ex` mount/3 hardcoded
  `session://system/default/main` for every mount, and
  `handle_params(%{"session" => encoded}, ...)` called
  `select_session/2` (and thereby `load_session_messages/1`) BEFORE any
  workspace/cap check. A tenant operator deep-linking
  `?session=<foreign-workspace-session>` got messages from sessions in
  workspaces they don't belong to.

  Post-fix:

    1. The main session URI defaults to
       `session://default/<caller-workspace>/main` (derived from
       `socket.assigns.current_workspace_uri`).
    2. `select_session/2` runs `authorize_session_view/2` first; on
       cross-workspace denial, the LV surfaces a flash and leaves the
       current session unchanged WITHOUT calling
       `load_session_messages/1`.

  Verified here against the empirically-observed violator shape
  (Allen 2026-05-27 02:47 RPC):
    - A non-admin user in `workspace://h2oslabs` deep-linking
      `?session=session://system/default/main`. Must be denied.
  """

  use ExUnit.Case

  # #52 Mode-A: cross-tier LiveView suite — mounts views that resolve
  # sibling-app domain modules; runs only in the umbrella. Excluded
  # standalone (`cd apps/ezagent_plugin_liveview && mix test`).
  @moduletag :umbrella_only
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Create a tenant user in `workspace://team-alpha` (non-system,
    # non-admin). The admin user lives in `workspace://system` and
    # holds bootstrap cross-workspace authority — that path is tested
    # separately below.
    tenant_uri_str = "entity://team-alpha/user/tenant-#{System.unique_integer([:positive])}"
    {:ok, _user} = Ezagent.Users.create(Ezagent.URI.new!(tenant_uri_str), nil, [])

    conn_tenant =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => tenant_uri_str,
        "current_workspace_uri" => "workspace://team-alpha"
      })

    conn_admin =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, conn_tenant: conn_tenant, conn_admin: conn_admin}
  end

  describe "mount default session URI is workspace-derived (CRIT-2 a)" do
    test "tenant operator's mount renders session://team-alpha/default/main, NOT system/main",
         %{conn_tenant: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")

      assert html =~ "session://team-alpha/default/main"

      # The system workspace's session URI MUST NOT appear in the
      # tenant's mount HTML (regression for hardcoded
      # `@main_session_uri = "session://system/default/main"`).
      refute html =~ "session://system/default/main"
    end

    test "admin operator's mount still renders session://system/default/main",
         %{conn_admin: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")
      # Backward-compat — admin's workspace IS `system`, so derivation
      # gives the same URI as the pre-fix hardcoded constant.
      assert html =~ "session://system/default/main"
    end
  end

  describe "deep-link session= query param is workspace-gated (CRIT-2 b)" do
    test "tenant deep-link to foreign session URI is REFUSED + flash surfaced",
         %{conn_tenant: conn} do
      foreign_session = "session://system/default/main"
      encoded = URI.encode_www_form(foreign_session)

      {:ok, lv, _html_initial} = live(conn, "/sessions")

      # Trigger the deep-link via patch (handle_params/3 path).
      html_after = render_patch(lv, "/sessions?session=#{encoded}")

      # Flash must surface the cross-workspace denial.
      assert html_after =~ "Cross-workspace denied" or
               html_after =~ "different workspace",
             "expected cross-workspace denial flash; got: #{String.slice(html_after, 0, 800)}"

      # The LV's current session URI MUST stay on team-alpha's main
      # (it was not changed to the foreign session).
      assert html_after =~ "session://team-alpha/default/main"
    end

    test "tenant deep-link to OWN-workspace session IS allowed",
         %{conn_tenant: conn} do
      # The tenant's own workspace main session is the default — a
      # deep-link to it is a no-op that must NOT trigger the gate.
      own_session = "session://team-alpha/default/main"
      encoded = URI.encode_www_form(own_session)

      {:ok, lv, _html} = live(conn, "/sessions")
      html_after = render_patch(lv, "/sessions?session=#{encoded}")

      refute html_after =~ "Cross-workspace denied"
      assert html_after =~ own_session
    end

    test "admin (system member) deep-link to ANY workspace session bypasses the gate",
         %{conn_admin: conn} do
      # System-workspace members hold structural cross-workspace
      # authority per SPEC v3 §13.1 — `Ezagent.Capability.cross_workspace?/2`
      # returns true via `member_of_system?/1` even without an explicit
      # `workspace_uri: :any` cap.
      #
      # We only need to verify the GATE doesn't fire — whether the
      # underlying session exists is orthogonal (the regression we
      # care about is: admin must NOT see the cross-workspace flash).
      foreign_session = "session://team-alpha/default/main"
      encoded = URI.encode_www_form(foreign_session)

      {:ok, lv, _html} = live(conn, "/sessions")

      html_after = render_patch(lv, "/sessions?session=#{encoded}")

      refute html_after =~ "Cross-workspace denied",
             "admin must bypass workspace gate via system-member authority " <>
               "(html=#{String.slice(html_after, 0, 500)})"
    end
  end
end
