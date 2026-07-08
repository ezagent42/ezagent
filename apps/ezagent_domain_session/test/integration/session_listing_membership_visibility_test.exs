defmodule EzagentDomainInstanceMessage.Integration.SessionListingMembershipVisibilityTest do
  @moduledoc """
  Session listing must NOT leak sessions to non-members.

  The bug (found by Allen 2026-07-07): on app.ezagent.chat/sessions, a user
  can see sessions they are NOT a member of. The READ side (session listing)
  returned all sessions in the workspace without membership filtering.

  This test proves:
    (a) A non-member CANNOT see a session they are not part of via list_sessions/2
    (b) A member CAN see their own session
    (c) An admin CAN see all sessions (management bypass)

  The failing-first case (on unmodified main): list_sessions/1 returns ALL
  workspace sessions regardless of caller — any user sees every session.
  The list_sessions/2 arity (added by the fix) filters by membership.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Entity.User, Users}

  @workspace_uri URI.new!("workspace://system")

  setup do
    # Seed a "main" session (required by EzagentCore.DataCase contract #92).
    _ =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "main",
        User.admin_uri(),
        template_name: "default"
      )

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp create_session(short, creator_uri) do
    {:ok, uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        short,
        creator_uri,
        template_name: "default"
      )

    uri
  end

  defp make_user(handle) do
    uri_str =
      "entity://system/user/" <> handle <> "_#{System.unique_integer([:positive])}"

    {:ok, _} = Users.create(uri_str, nil, [])
    uri = Ezagent.URI.new!(uri_str)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp wait_until(fun, retries \\ 50) do
    if fun.() or retries <= 0 do
      true
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end

  # ── tests ────────────────────────────────────────────────────────────

  describe "session listing visibility (membership-gated)" do
    test "a non-member does NOT see sessions they are not part of" do
      owner = make_user("owner")
      stranger = make_user("stranger")

      session_uri = create_session("priv-#{System.unique_integer([:positive])}", owner)

      # Wait for the session to appear in the live registry.
      assert wait_until(fn ->
               session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri)
             end)

      # Prove the bug EXISTS on the old workspace-only path:
      # list_sessions/1 returns the session to ANY workspace member.
      ws_sessions = EzagentDomainInstanceMessage.list_sessions(@workspace_uri)
      assert session_uri in ws_sessions

      # THE FIX: list_sessions/2 filters by membership.
      # The STRANGER (non-member) must NOT see the session.
      stranger_sessions =
        EzagentDomainInstanceMessage.list_sessions(@workspace_uri, stranger)

      refute session_uri in stranger_sessions

      # The OWNER (member) CAN see the session.
      owner_sessions = EzagentDomainInstanceMessage.list_sessions(@workspace_uri, owner)
      assert session_uri in owner_sessions
    end

    test "admin bypass: admin can see all sessions in the workspace" do
      owner = make_user("owner")
      admin = User.admin_uri()

      session_uri = create_session("adm-see-#{System.unique_integer([:positive])}", owner)

      assert wait_until(fn ->
               session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri)
             end)

      # Admin can see the session even though admin is not a member.
      admin_sessions = EzagentDomainInstanceMessage.list_sessions(@workspace_uri, admin)
      assert session_uri in admin_sessions
    end

    test "workspace scoping is preserved — different workspace returns empty" do
      owner = make_user("owner")

      session_uri = create_session("ws-gate-#{System.unique_integer([:positive])}", owner)

      assert wait_until(fn ->
               session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri)
             end)

      other_ws = URI.new!("workspace://other-tenant-#{System.unique_integer([:positive])}")

      # A different workspace should return empty regardless of caller.
      assert [] == EzagentDomainInstanceMessage.list_sessions(other_ws, owner)
    end

    test "nil or non-URI caller is fail-closed (empty list)" do
      owner = make_user("owner")
      session_uri = create_session("nil-caller-#{System.unique_integer([:positive])}", owner)

      assert wait_until(fn ->
               session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri)
             end)

      # nil caller → empty (unauthenticated cannot be a member)
      assert [] == EzagentDomainInstanceMessage.list_sessions(@workspace_uri, nil)

      # Non-URI caller → empty
      assert [] ==
               EzagentDomainInstanceMessage.list_sessions(@workspace_uri, "not-a-uri")
    end
  end
end
