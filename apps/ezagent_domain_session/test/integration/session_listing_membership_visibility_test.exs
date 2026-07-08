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

  # ── cold-boot durable listing (2026-07-08) ───────────────────────────
  #
  # After a container restart NO session Kind is live (sessions are not
  # auto-respawned on boot), but every session is durably persisted in
  # `kind_snapshots`. The live-only listing base made `/sessions` come up
  # EMPTY on a cold node (admin lin.yilun, nightly 2026-07-08). The fix
  # bases `list_sessions/2` on the live ∪ durable union and evaluates
  # membership for COLD sessions from the durable snapshot `:members` —
  # while the #1217 tenant-isolation invariant (non-members NEVER see the
  # session) must hold identically for cold sessions.
  #
  # NOTE for the security case: these tests deliberately read the snapshot
  # `:members` inline (not via the fix's new helper) so the tenant-invariant
  # test also runs — and passes — on unmodified pre-fix code.

  defp make_cold(session_uri) do
    {:ok, pid} = Ezagent.KindRegistry.lookup(session_uri)

    :ok =
      DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

    assert wait_until(fn -> Ezagent.KindRegistry.lookup(session_uri) == :error end),
           "session Kind did not go cold"
  end

  # Wait until the durable snapshot row exists AND its :chat slice members
  # include `member_uri` — the state a node restart preserves. Inline slice
  # unwrap on purpose (independent of the code under test).
  defp wait_snapshot_members(session_uri, member_uri) do
    member_str = URI.to_string(member_uri)

    wait_until(fn ->
      with row when not is_nil(row) <-
             Ezagent.Ecto.KindSnapshot.get(URI.to_string(session_uri)),
           {:ok, state} <- Ezagent.Ecto.KindSnapshot.decode_state(row) do
        chat_slice = Map.get(state, :chat, %{})
        chat_persistent = Map.get(chat_slice, :state, chat_slice)

        chat_persistent
        |> Map.get(:members, %{})
        |> Map.keys()
        |> Enum.any?(fn
          %URI{} = uri -> URI.to_string(uri) == member_str
          _ -> false
        end)
      else
        _ -> false
      end
    end)
  end

  describe "cold-boot durable session listing" do
    test "a MEMBER still sees their session after it goes cold (restart survival)" do
      owner = make_user("cold_owner")
      session_uri = create_session("cold-mem-#{System.unique_integer([:positive])}", owner)

      assert wait_until(fn ->
               session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri)
             end)

      assert wait_snapshot_members(session_uri, owner),
             "durable snapshot never captured the owner as :chat member"

      make_cold(session_uri)

      # Sanity: the live-only listing no longer sees it (it IS cold).
      refute session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri)

      # THE FIX (fails on pre-fix main — live-only base returns []):
      # the member-scoped listing includes the durably-persisted session.
      owner_sessions = EzagentDomainInstanceMessage.list_sessions(@workspace_uri, owner)
      assert session_uri in owner_sessions
    end

    test "tenant invariant: a cold session stays INVISIBLE to non-members (W0 stays closed)" do
      owner = make_user("cold_owner")
      stranger = make_user("cold_stranger")

      session_uri = create_session("cold-iso-#{System.unique_integer([:positive])}", owner)

      assert wait_until(fn ->
               session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri)
             end)

      assert wait_snapshot_members(session_uri, owner)
      make_cold(session_uri)

      # Same-workspace NON-MEMBER: must NOT see the cold session.
      stranger_sessions =
        EzagentDomainInstanceMessage.list_sessions(@workspace_uri, stranger)

      refute session_uri in stranger_sessions

      # CROSS-WORKSPACE caller: must NOT see it either (not a member, not
      # an admin — membership is matched against the session's OWN durable
      # member set only).
      outsider =
        Ezagent.URI.new!(
          "entity://other-tenant-#{System.unique_integer([:positive])}/user/outsider"
        )

      outsider_sessions =
        EzagentDomainInstanceMessage.list_sessions(@workspace_uri, outsider)

      refute session_uri in outsider_sessions

      # WORKSPACE SCOPE on the durable base: listing ANOTHER workspace never
      # surfaces this workspace's cold session — even for its own member.
      other_ws = URI.new!("workspace://other-tenant-#{System.unique_integer([:positive])}")
      assert [] == EzagentDomainInstanceMessage.list_sessions(other_ws, owner)
    end

    test "live parity: live-session visibility is unchanged by the durable base" do
      owner = make_user("parity_owner")
      stranger = make_user("parity_stranger")

      session_uri = create_session("parity-#{System.unique_integer([:positive])}", owner)

      assert wait_until(fn ->
               session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri)
             end)

      # Live session, live membership read — exactly the #1217 behavior.
      assert session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri, owner)

      refute session_uri in EzagentDomainInstanceMessage.list_sessions(@workspace_uri, stranger)
    end
  end
end
