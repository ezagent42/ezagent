defmodule EzagentWeb.Plugs.RequireEntityTest do
  @moduledoc """
  PR #142 — RequireUser renamed to RequireEntity. Session key
  `current_user_uri` renamed to `current_entity_uri`. The plug
  now accepts both entity://user/* and entity://agent/* URIs in
  the session (any entity, not just users).

  task #180 Change 3 — the plug also EVICTS a user whose account was
  disabled/deleted AFTER login (active-session eviction). That recheck
  reads the `users` table, so this suite runs under `DataCase` (DB
  sandbox) rather than the old async no-DB `ExUnit.Case`.
  """
  use EzagentCore.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias EzagentWeb.Plugs.RequireEntity
  alias Ezagent.Users

  describe "RequireEntity plug" do
    test "redirects to /login + halts when no session" do
      conn =
        conn(:get, "/admin")
        |> init_test_session(%{})
        |> RequireEntity.call([])

      assert conn.halted
      assert ["/login"] = get_resp_header(conn, "location")
    end

    test "passes through + assigns current_entity_uri for an ACTIVE entity://user/*" do
      # Seeded, not disabled → the Change 3 recheck lets it through.
      name = "active-#{System.unique_integer([:positive])}"
      uri = "entity://system/user/#{name}"
      {:ok, _} = Users.create(uri, "pw", [])

      conn =
        conn(:get, "/admin")
        |> init_test_session(%{"current_entity_uri" => uri})
        |> RequireEntity.call([])

      refute conn.halted

      # Phase 9 PR-8: admin URI is in workspace://system.
      assert %URI{scheme: "entity", host: "system", path: "/user/" <> ^name} =
               conn.assigns.current_entity_uri
    end

    test "passes through + assigns current_entity_uri for entity://agent/* (agents exempt from user recheck)" do
      conn =
        conn(:get, "/admin")
        |> init_test_session(%{"current_entity_uri" => "entity://team-alpha/agent/cc_test"})
        |> RequireEntity.call([])

      refute conn.halted

      assert %URI{scheme: "entity", host: "team-alpha", path: "/agent/cc_test"} =
               conn.assigns.current_entity_uri
    end

    test "rejects malformed (non-entity scheme) session URI" do
      conn =
        conn(:get, "/admin")
        |> init_test_session(%{"current_entity_uri" => "session://system/default/main"})
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

  describe "active-session eviction (task #180 Change 3)" do
    test "a user disabled AFTER login is bounced to /login on the next request" do
      uri = "entity://team-alpha/user/evict-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "pw", [])

      # First request: active → passes through.
      conn =
        conn(:get, "/sessions")
        |> init_test_session(%{"current_entity_uri" => uri})
        |> RequireEntity.call([])

      refute conn.halted

      # Operator disables the account.
      {:ok, _} = Users.disable(uri, "entity://system/user/admin", "offboarded")

      # Next request: the live cookie is now evicted.
      conn2 =
        conn(:get, "/sessions")
        |> init_test_session(%{"current_entity_uri" => uri})
        |> RequireEntity.call([])

      assert conn2.halted
      assert ["/login"] = get_resp_header(conn2, "location")
    end

    test "a tombstoned (deleted) user is likewise bounced" do
      uri = "entity://team-alpha/user/evict-del-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "pw", [])
      {:ok, _} = Users.disable(uri, "entity://system/user/admin", "off")
      {:ok, _} = Users.tombstone(uri, "entity://system/user/admin", "gone")

      conn =
        conn(:get, "/sessions")
        |> init_test_session(%{"current_entity_uri" => uri})
        |> RequireEntity.call([])

      assert conn.halted
      assert ["/login"] = get_resp_header(conn, "location")
    end
  end
end
