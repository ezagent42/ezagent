defmodule EzagentWeb.WorkspaceSwitchControllerTest do
  @moduledoc """
  Phase 9 PR-8 (SPEC v3 §6.4 amendment 3 + §13.2) — permission-gated
  workspace switcher tests.

  Branching:
  - System member (`workspace://system`) → context swap (no logout);
    `:current_entity_uri` preserved, `:current_workspace_uri`
    updated to target.
  - Regular user → denial page rendered (HTML 200 with "Sign in
    to" prompt). Session UNCHANGED. This covers BOTH switching to a
    sibling tenant workspace AND attempting to switch to
    `workspace://system` (SPEC 2026-05-27-workspace-cap-based-visibility
    folded the former "hidden workspace" early-exit into the regular
    denial branch since the `:visible` field is gone).
  - Unknown workspace → flash error redirect.
  - No-op when already in target.
  """
  use EzagentCore.DataCase
  use Phoenix.ConnTest

  @endpoint EzagentWeb.Endpoint

  setup do
    # Visible team workspace target (regular operator-created).
    ws_name = "team-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Workspace.Store.create(ws_name, %{})

    # System workspace must exist for system-member tests.
    case Ezagent.Workspace.Store.get_by_name("system") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("system", %{})
      _ -> :ok
    end

    # Default workspace must exist so default-workspace user URIs
    # round-trip through SessionPrincipal.
    case Ezagent.Workspace.Store.get_by_name("default") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("default", %{})
      _ -> :ok
    end

    regular_uri = "entity://team-alpha/user/wsswitch-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Users.create(regular_uri, "pw", [])

    %{
      regular_uri: regular_uri,
      target_workspace: ws_name,
      admin_uri: URI.to_string(Ezagent.Entity.User.admin_uri())
    }
  end

  describe "POST /workspaces/switch — system member context swap" do
    test "happy path: system member → 302 to /sessions + workspace slot swapped, entity preserved",
         %{admin_uri: admin_uri, target_workspace: target} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => admin_uri,
          "current_workspace_uri" => "workspace://system"
        })
        |> post("/workspaces/switch", %{"workspace" => target})

      assert redirected_to(conn) == "/sessions"

      # Entity URI preserved — admin stays admin.
      assert Plug.Conn.get_session(conn, :current_entity_uri) == admin_uri

      # Workspace slot swapped to target.
      assert Plug.Conn.get_session(conn, :current_workspace_uri) ==
               "workspace://" <> target

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Operating on workspace"
    end
  end

  describe "POST /workspaces/switch — regular user denial" do
    test "regular user → denial page rendered (HTML 200), session UNCHANGED",
         %{regular_uri: uri, target_workspace: target} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => uri,
          "current_workspace_uri" => "workspace://team-alpha"
        })
        |> post("/workspaces/switch", %{"workspace" => target})

      # Denial page is a 200 HTML response (NOT a redirect).
      assert conn.status == 200
      body = response(conn, 200)
      assert body =~ "Sign in to workspace"
      assert body =~ target

      # Session preserved — user can keep using their current
      # workspace if they cancel.
      assert Plug.Conn.get_session(conn, :current_entity_uri) == uri
      assert Plug.Conn.get_session(conn, :current_workspace_uri) == "workspace://team-alpha"
    end
  end

  describe "POST /workspaces/switch — edge cases" do
    test "unknown workspace → 302 to /sessions, flash error, session UNCHANGED",
         %{regular_uri: uri} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => uri,
          "current_workspace_uri" => "workspace://team-alpha"
        })
        |> post("/workspaces/switch", %{"workspace" => "no-such-workspace"})

      assert redirected_to(conn) == "/sessions"
      assert Plug.Conn.get_session(conn, :current_entity_uri) == uri
      assert Plug.Conn.get_session(conn, :current_workspace_uri) == "workspace://team-alpha"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unknown workspace"
    end

    test "regular user → system workspace renders denial page (post-SPEC 2026-05-27 — no `visible` field)",
         %{regular_uri: uri} do
      # SPEC 2026-05-27-workspace-cap-based-visibility folded the
      # former "hidden workspace (visible: false)" early-exit into
      # the regular denial branch. Regular users attempting to
      # switch to `workspace://system` now get the same denial page
      # they'd get switching to any other tenant's workspace —
      # consistent with cap-based visibility: if you can't see it,
      # you can't switch to it; the switcher denies you uniformly.
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => uri,
          "current_workspace_uri" => "workspace://team-alpha"
        })
        |> post("/workspaces/switch", %{"workspace" => "system"})

      # Denial page is a 200 HTML response (NOT a redirect).
      assert conn.status == 200
      body = response(conn, 200)
      assert body =~ "Sign in to workspace"
      assert body =~ "system"

      # Session preserved — user can keep using their current
      # workspace if they cancel.
      assert Plug.Conn.get_session(conn, :current_entity_uri) == uri
      assert Plug.Conn.get_session(conn, :current_workspace_uri) == "workspace://team-alpha"
    end

    test "no-op when already in target workspace → just redirect to /sessions",
         %{admin_uri: admin_uri} do
      # System member already in target (e.g. clicked their own ws).
      # Using "system" is blocked by the hidden check; use a real
      # transition where workspace_slot already equals target.
      target = "team-noop-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Workspace.Store.create(target, %{})

      # NOTE: this branch fires for REGULAR users whose
      # current_workspace equals target (admin is a system member,
      # which goes through the context-swap branch).
      regular = "entity://" <> target <> "/user/u-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(regular, "pw", [])

      _ = admin_uri

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => regular,
          "current_workspace_uri" => "workspace://" <> target
        })
        |> post("/workspaces/switch", %{"workspace" => target})

      assert redirected_to(conn) == "/sessions"
    end

    test "missing workspace param → 302 to /sessions, flash error",
         %{regular_uri: uri} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => uri})
        |> post("/workspaces/switch", %{})

      assert redirected_to(conn) == "/sessions"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing workspace"
    end

    test "anonymous (no session) is bounced by RequireEntity before reaching the controller",
         %{target_workspace: target} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/workspaces/switch", %{"workspace" => target})

      # RequireEntity catches the unauthenticated request and redirects
      # to /login — the switch endpoint is mounted inside that pipeline
      # for exactly this reason (no anonymous session-clearing spam).
      assert redirected_to(conn) =~ "/login"
    end
  end
end
