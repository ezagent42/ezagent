defmodule EzagentWeb.Plugs.RequireEntityTest do
  @moduledoc """
  PR #142 — RequireUser renamed to RequireEntity. Session key
  `current_user_uri` renamed to `current_entity_uri`. The plug
  now accepts both entity://user/* and entity://agent/* URIs in
  the session (any entity, not just users).
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias EzagentWeb.Plugs.RequireEntity

  describe "RequireEntity plug" do
    test "redirects to /login + halts when no session" do
      conn =
        conn(:get, "/admin")
        |> init_test_session(%{})
        |> RequireEntity.call([])

      assert conn.halted
      assert ["/login"] = get_resp_header(conn, "location")
    end

    test "passes through + assigns current_entity_uri for entity://user/*" do
      conn =
        conn(:get, "/admin")
        |> init_test_session(%{"current_entity_uri" => "entity://user/system/admin"})
        |> RequireEntity.call([])

      refute conn.halted

      # Phase 9 PR-8: admin URI is in workspace://system.
      assert %URI{scheme: "entity", host: "user", path: "/system/admin"} =
               conn.assigns.current_entity_uri
    end

    test "passes through + assigns current_entity_uri for entity://agent/*" do
      conn =
        conn(:get, "/admin")
        |> init_test_session(%{"current_entity_uri" => "entity://agent/team-alpha/cc_test"})
        |> RequireEntity.call([])

      refute conn.halted

      assert %URI{scheme: "entity", host: "agent", path: "/team-alpha/cc_test"} =
               conn.assigns.current_entity_uri
    end

    test "rejects malformed (non-entity scheme) session URI" do
      conn =
        conn(:get, "/admin")
        |> init_test_session(%{"current_entity_uri" => "session://default/system/main"})
        |> RequireEntity.call([])

      assert conn.halted
      assert ["/login"] = get_resp_header(conn, "location")
    end

    # Layer 2 of the 2026-05-20 defense-in-depth: bare-string session
    # values bounce. This is what made Allen's symptom visible — the
    # principal slot held literally "admin" (raw user input) and on
    # every subsequent request RequireEntity rejected it. The fix is
    # at the write site (SessionPrincipal), but this test guards the
    # READ side so a regression on either side fails closed.
    test "rejects bare-string (non-URI) session value — closes the bare-handle hole" do
      for raw <- ["admin", "ADMIN", "user-123", "", "   "] do
        conn =
          conn(:get, "/admin")
          |> init_test_session(%{"current_entity_uri" => raw})
          |> RequireEntity.call([])

        assert conn.halted, "raw #{inspect(raw)} should have halted"
        assert ["/login"] = get_resp_header(conn, "location")
      end
    end
  end
end
