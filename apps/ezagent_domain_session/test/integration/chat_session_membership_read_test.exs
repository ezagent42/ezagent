defmodule EzagentDomainInstanceMessage.Integration.ChatSessionMembershipReadTest do
  @moduledoc """
  P5-A — the chat `Session` publisher READ actions (`:snapshot` / `:history`)
  are now **membership-gated** (the `SocialwarePublisherRead` model:
  cap-EXEMPT at the CapBAC layer + a LIVE in-handler owner/member check against
  the `:chat` slice), NOT the old `Publisher.SessionImpl` CapBAC cap-gated read.

  Drives the PRODUCTION dispatch path through `Session.snapshot/2` +
  `Session.history/4` (which build `?action=publisher.snapshot|history` and go
  through `Invocation.dispatch/1`).

  Proves the authority MOVED from cap to membership:

    (a) a chat-session MEMBER (owner) CAN read `:snapshot`/`:history`;
    (b) a chat-session NON-member is DENIED even when they hold the OLD
        `Publisher.SessionImpl :snapshot` / `:history` cap — the cap no longer
        carries authority; membership does.

  `:subscribe_from` is UNCHANGED (still `Publisher.SessionImpl`, CapBAC
  cap-gated) — see `publisher_session_test.exs`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.KindRegistry

  # ----- fixtures --------------------------------------------------------

  defp spawn_owned_session(owner_uri) do
    {:ok, _row} = Ezagent.Users.create(owner_uri, "pw-not-secret", [])
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: owner_uri})

    session_uri =
      Ezagent.URI.new!(
        "session://team-alpha/default/membership-read-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: owner_uri
      })

    :ok =
      Ezagent.WorkspaceRegistry.bind(
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    :ok = Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(session_uri, owner_uri)

    admin = User.admin_uri()
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    {:ok, join_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    assert {:ok, _joined} =
             Ezagent.Invocation.dispatch(%Ezagent.Invocation{
               origin: :trusted_internal,
               target: target,
               mode: :call,
               args: %{member: owner_uri},
               ctx: %{
                 caller: admin,
                 authenticated_principal: admin,
                 caps: MapSet.new([join_cap]),
                 reply: :ignore
               }
             })

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(
            EzagentDomainInstanceMessage.SessionSupervisor,
            pid
          )

        :error ->
          :ok
      end
    end)

    session_uri
  end

  # A real owner/member identity URI (a bare principal — what the live
  # ChatMembership check requires for `ctx.caller`).
  defp member_uri do
    Ezagent.URI.new!("entity://team-alpha/user/chat-member-#{System.unique_integer([:positive])}")
  end

  # ctx for a caller that is the session's owner/member. No caps needed —
  # the reads are cap-exempt; the membership check is the authority.
  defp member_ctx(uri),
    do: %{caller: uri, authenticated_principal: uri, caps: Ezagent.Identity.list_caps_for(uri)}

  # ctx for a NON-member who holds the OLD Publisher.SessionImpl read caps.
  # The membership-gated read must DENY despite the held caps.
  defp stranger_with_old_caps_ctx(session_uri) do
    stranger =
      Ezagent.URI.new!(
        "entity://team-alpha/user/old-cap-stranger-#{System.unique_integer([:positive])}"
      )

    old_snapshot_cap = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Publisher.SessionImpl,
      action: :snapshot,
      instance: :any,
      workspace_uri: Ezagent.Capability.workspace_of(session_uri),
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }

    old_history_cap = %{old_snapshot_cap | action: :history}

    %{
      caller: stranger,
      authenticated_principal: stranger,
      caps: MapSet.new([old_snapshot_cap, old_history_cap])
    }
  end

  # ----- (a) a MEMBER (owner) can read -----------------------------------

  describe "(a) a chat-session member/owner can read (membership-gated, cap-exempt)" do
    test "snapshot: the owner reads successfully with NO caps" do
      owner = member_uri()
      session_uri = spawn_owned_session(owner)

      assert {:ok, %{cursor: _, state: _}} = Session.snapshot(session_uri, member_ctx(owner))
    end

    test "history: the owner reads the window successfully with NO caps" do
      owner = member_uri()
      session_uri = spawn_owned_session(owner)

      assert {:ok, events} = Session.history(session_uri, :earliest, :latest, member_ctx(owner))
      assert is_list(events)
    end
  end

  # ----- (b) a NON-member is denied even with the OLD cap ----------------

  describe "(b) a non-member is denied even holding the OLD Publisher.SessionImpl read cap" do
    test "snapshot: stranger with the old :snapshot cap → unauthorized (authority is membership)" do
      owner = member_uri()
      session_uri = spawn_owned_session(owner)

      assert {:error, :unauthorized} =
               Session.snapshot(session_uri, stranger_with_old_caps_ctx(session_uri))
    end

    test "history: stranger with the old :history cap → unauthorized" do
      owner = member_uri()
      session_uri = spawn_owned_session(owner)

      assert {:error, :unauthorized} =
               Session.history(
                 session_uri,
                 :earliest,
                 :latest,
                 stranger_with_old_caps_ctx(session_uri)
               )
    end
  end

  # ----- :subscribe_from authority is UNCHANGED (still cap-gated) --------

  describe ":subscribe_from is still Publisher.SessionImpl + CapBAC cap-gated (unchanged by P5-A)" do
    test "a caller with empty caps cannot subscribe (step 5.5 still denies)" do
      owner = member_uri()
      session_uri = spawn_owned_session(owner)

      assert {:error, :missing_cap} =
               Session.subscribe_from(session_uri, self(), :latest, member_ctx(owner))
    end
  end

  describe "strict live membership read" do
    test "returns the current owner/member" do
      owner = member_uri()
      session_uri = spawn_owned_session(owner)

      assert {:ok, members} = Session.session_member_uris_strict(session_uri)
      assert owner in members
    end

    test "an unavailable Session is an error, not an empty roster" do
      missing =
        Ezagent.URI.new!(
          "session://team-alpha/default/missing-roster-#{System.unique_integer([:positive])}"
        )

      assert {:error, _reason} = Session.session_member_uris_strict(missing)
      assert Session.session_member_uris(missing) == []
    end
  end
end
