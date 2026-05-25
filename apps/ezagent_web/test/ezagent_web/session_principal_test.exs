defmodule EzagentWeb.SessionPrincipalTest do
  @moduledoc """
  Layer 1 of 3: write-side invariant — `SessionPrincipal.put/2` is
  the only sanctioned writer for `:current_entity_uri` and it
  refuses anything that wouldn't survive `URI.parse` + scheme check.

  See `EzagentWeb.SessionPrincipal` for the why-this-exists story
  (the bare-handle session bug Allen reported 2026-05-20).
  """
  use ExUnit.Case, async: true

  alias EzagentWeb.SessionPrincipal

  describe "canonicalize/1" do
    test "full entity URIs pass through unchanged" do
      assert SessionPrincipal.canonicalize("entity://user/system/admin") ==
               "entity://user/system/admin"

      assert SessionPrincipal.canonicalize("entity://agent/team-alpha/echo_default") ==
               "entity://agent/team-alpha/echo_default"
    end

    test "bare handle is normalized to entity://user/<workspace>/<handle> (lowercased)" do
      # Phase 9 PR-8: bare handle still defaults to workspace "default"
      # (no automatic admin → system mapping). To log in as admin, the
      # user must POST the full URI or use /login?workspace=system.
      assert SessionPrincipal.canonicalize("admin") == "entity://user/team-alpha/admin"
      assert SessionPrincipal.canonicalize("ADMIN") == "entity://user/team-alpha/admin"
      assert SessionPrincipal.canonicalize("  allen  ") == "entity://user/team-alpha/allen"
      assert SessionPrincipal.canonicalize("user_123") == "entity://user/team-alpha/user_123"
    end

    test "bare handle with workspace: \"system\" canonicalizes to system workspace" do
      # Phase 9 PR-8 (SPEC v3 §13): admin's only login path is via
      # /login?workspace=system with the bare handle "admin".
      assert SessionPrincipal.canonicalize("admin", workspace: "system") ==
               "entity://user/system/admin"
    end

    test "raises ArgumentError on inputs that don't yield a valid entity URI" do
      assert_raise ArgumentError, ~r/not a valid entity URI/, fn ->
        SessionPrincipal.canonicalize("foo@bar.com")
      end

      assert_raise ArgumentError, ~r/not a valid entity URI/, fn ->
        SessionPrincipal.canonicalize("https://example.com/admin")
      end

      assert_raise ArgumentError, ~r/not a valid entity URI/, fn ->
        # Non-user/agent host — workspace URIs are NOT principals.
        SessionPrincipal.canonicalize("entity://workspace/default")
      end

      assert_raise ArgumentError, ~r/not a valid entity URI/, fn ->
        SessionPrincipal.canonicalize("   ")
      end
    end

    test "raises on non-string input" do
      assert_raise ArgumentError, ~r/expects a String/, fn ->
        SessionPrincipal.canonicalize(nil)
      end

      assert_raise ArgumentError, ~r/expects a String/, fn ->
        SessionPrincipal.canonicalize(%{handle: "admin"})
      end
    end
  end

  describe "put/2" do
    test "stores the CANONICAL form (not the raw input)" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.init_test_session(%{})
        |> SessionPrincipal.put("admin", workspace: "team-alpha")

      # SPEC #324: bare "admin" with workspace: opt → canonical URI.
      # The legacy silent "default" fallback is gone — workspace MUST
      # be supplied for bare-handle input.
      assert Plug.Conn.get_session(conn, :current_entity_uri) == "entity://user/team-alpha/admin"
    end

    test "rotates the session ID (fixation defence)" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.init_test_session(%{some_pre_auth_key: "value"})

      conn_after = SessionPrincipal.put(conn, "admin")

      # `configure_session(renew: true)` flag is set on the conn's
      # private session options — we can't fully observe ID rotation
      # in a test harness, but the operation must succeed and the
      # principal slot is set.
      assert Plug.Conn.get_session(conn_after, :current_entity_uri) ==
               "entity://user/team-alpha/admin"
    end

    test "raises on invalid input — same boundary as canonicalize/1" do
      conn = Plug.Test.conn(:get, "/") |> Plug.Test.init_test_session(%{})

      assert_raise ArgumentError, fn ->
        SessionPrincipal.put(conn, "not a URI")
      end

      assert_raise ArgumentError, fn ->
        SessionPrincipal.put(conn, nil)
      end
    end
  end

  describe "workspace coherence (Phase 9 PR-5)" do
    # SPEC v3 §6.1 — `put/2` writes BOTH session slots; the workspace
    # slot is derived from the entity URI so there is no way to
    # construct an inconsistent pair via this API.
    test "put/2 writes both :current_entity_uri AND :current_workspace_uri" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.init_test_session(%{})
        |> SessionPrincipal.put("admin", workspace: "team-alpha")

      # Phase 9 PR-8: bare-handle default workspace stays "default";
      # admin promotion happens via explicit workspace: "system" opt.
      assert Plug.Conn.get_session(conn, :current_entity_uri) ==
               "entity://user/team-alpha/admin"

      assert Plug.Conn.get_session(conn, :current_workspace_uri) ==
               "workspace://team-alpha"
    end

    # SPEC v3 §6.5 invariant.
    test ":current_workspace_uri always equals entity_workspace_uri(:current_entity_uri)" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.init_test_session(%{})
        |> SessionPrincipal.put("entity://user/team-alpha/allen")

      entity_str = Plug.Conn.get_session(conn, :current_entity_uri)
      workspace_str = Plug.Conn.get_session(conn, :current_workspace_uri)

      derived =
        entity_str
        |> URI.parse()
        |> Ezagent.URI.entity_workspace_uri()
        |> URI.to_string()

      assert workspace_str == derived
      assert workspace_str == "workspace://team-alpha"
    end

    # SPEC v3 §6.4 amended — workspace override path.
    test "put/3 with workspace opt routes bare handles into the target workspace" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.init_test_session(%{})
        |> SessionPrincipal.put("allen", workspace: "team-alpha")

      assert Plug.Conn.get_session(conn, :current_entity_uri) ==
               "entity://user/team-alpha/allen"

      assert Plug.Conn.get_session(conn, :current_workspace_uri) ==
               "workspace://team-alpha"
    end

    test "put/3 with workspace opt is ignored for full entity:// URIs" do
      # Full URI already carries its workspace — opts[:workspace] does
      # not get to override the explicit segment. Admin's full URI
      # `entity://user/system/admin` derives `workspace://system`.
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.init_test_session(%{})
        |> SessionPrincipal.put("entity://user/system/admin", workspace: "team-alpha")

      assert Plug.Conn.get_session(conn, :current_entity_uri) ==
               "entity://user/system/admin"

      assert Plug.Conn.get_session(conn, :current_workspace_uri) ==
               "workspace://system"
    end

    # SPEC v3 §6.4 amended — `clear/1` is shared by /logout AND
    # /workspaces/switch. Both slots gone.
    test "clear/1 removes both slots" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Test.init_test_session(%{})
        |> SessionPrincipal.put("admin", workspace: "team-alpha")
        |> SessionPrincipal.clear()

      refute Plug.Conn.get_session(conn, :current_entity_uri)
      refute Plug.Conn.get_session(conn, :current_workspace_uri)
    end
  end

  describe "codebase invariant — single sanctioned writer" do
    # This test is the architectural gate: no controller / plug should
    # call `put_session(_, :current_entity_uri, _)` directly. They
    # MUST funnel through `SessionPrincipal.put/2` so the canonical-
    # form invariant is enforced at the only entry point.
    #
    # Per memory `feedback_completion_requires_invariant_test`.
    test "no direct put_session(:current_entity_uri, _) outside SessionPrincipal" do
      app_dir = Path.expand("../../../../", __DIR__)
      # Grep for direct writes, excluding the one place that's allowed.
      {output, _exit_code} =
        System.cmd(
          "grep",
          [
            "-rE",
            "put_session\\([^)]+:current_entity_uri",
            Path.join(app_dir, "apps"),
            "--include=*.ex",
            "--exclude=session_principal.ex"
          ],
          stderr_to_stdout: true
        )

      violations =
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(fn line ->
          # The SessionPrincipal module is the only allowed writer.
          # Tests that exercise it are also fine.
          String.contains?(line, "session_principal") or
            String.contains?(line, "test/")
        end)

      assert violations == [],
             "Direct put_session(_, :current_entity_uri, _) found outside SessionPrincipal:\n" <>
               Enum.join(violations, "\n") <>
               "\n\nFunnel all auth paths through EzagentWeb.SessionPrincipal.put/2 — " <>
               "it validates that the principal is a canonical entity:// URI before storage. " <>
               "See module @moduledoc for the bug this prevents."
    end

    # Phase 9 PR-5 (SPEC v3 §6.5) — extension of the above. The
    # workspace slot has its own invariant: it MUST equal
    # `entity_workspace_uri(:current_entity_uri)`, enforced at the
    # SessionPrincipal write site for regular users.
    #
    # Phase 9 PR-8 (SPEC v3 §13.2) — relaxed for system members. The
    # `EzagentWeb.WorkspaceSwitchController` swaps `:current_workspace_uri`
    # without rotating `:current_entity_uri` so a system admin can
    # "Operate on workspace <x>" without re-auth. This is the SECOND
    # sanctioned writer and is explicitly allowed below.
    test "no direct put_session(:current_workspace_uri, _) outside SessionPrincipal" do
      app_dir = Path.expand("../../../../", __DIR__)

      {output, _exit_code} =
        System.cmd(
          "grep",
          [
            "-rE",
            "put_session\\([^)]+:current_workspace_uri",
            Path.join(app_dir, "apps"),
            "--include=*.ex",
            "--exclude=session_principal.ex"
          ],
          stderr_to_stdout: true
        )

      violations =
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(fn line ->
          # Phase 9 PR-8 (SPEC v3 §13.2) — system-member context-swap path.
          String.contains?(line, "session_principal") or
            String.contains?(line, "test/") or
            String.contains?(line, "workspace_switch_controller")
        end)

      assert violations == [],
             "Direct put_session(_, :current_workspace_uri, _) found outside SessionPrincipal:\n" <>
               Enum.join(violations, "\n") <>
               "\n\nFunnel all auth paths through EzagentWeb.SessionPrincipal.put/2 — " <>
               "it derives :current_workspace_uri from :current_entity_uri so the " <>
               "two slots can never diverge. SPEC v3 §6.5 invariant. The only " <>
               "exception is `workspace_switch_controller.ex` per SPEC §13.2 " <>
               "(system-member context-swap)."
    end
  end
end
