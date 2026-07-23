defmodule Ezagent.Socialware.AnonAccessMembershipTest do
  @moduledoc """
  Issue #51 — the membership-only access path proven end-to-end at the source
  layer (real `Session` Kind, real dispatch, real `ChatFeed` read):

    * a minted anon-User, once `session.join`'d, READS the session via the
      membership-gated `ChatFeed.snapshot/2` — exactly the same predicate
      (`Ezagent.Session.Membership.authorize/2`) every real member uses;
    * a NON-joined anon-User (or any non-member) is DENIED;
    * an anon-User for session A cannot read session B (membership is per-session),
      and the `ChatFeedAuth` token bound to A fails `verify` for B.

  The read authority is UNCHANGED by anon access — there is no new "non-member can
  read" permission. The anon-User reads because it is a real member (spec §2).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.{KindRegistry, Message, MessageStore}
  alias Ezagent.Socialware.{AnonUser, ChatFeed, ChatFeedAuth}

  @owner Ezagent.URI.user(:system, :admin)

  # ----- fixtures --------------------------------------------------------

  defp spawn_session(owner_uri \\ @owner) do
    session_uri =
      Ezagent.URI.new!(
        "session://team-alpha/default/anon-access-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session_uri,
        owner_uri: owner_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok =
      Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

        :error ->
          :ok
      end
    end)

    session_uri
  end

  # Spawn the anon-User Kind so it is a registered member-target for the join.
  defp spawn_anon_kind(anon_uri) do
    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{
        uri: anon_uri,
        initial_caps: User.initial_caps_for_spawn(anon_uri)
      })

    on_exit(fn ->
      case KindRegistry.lookup(anon_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(
            EzagentDomainIdentity.Application.UserSupervisor,
            pid
          )

        :error ->
          :ok
      end
    end)

    :ok
  end

  # Join `member_uri` into `session_uri` via the PRODUCTION dispatch path.
  defp join(session_uri, member_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    caller = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: MapSet.new([cap]),
        reply: :ignore
      }
    })
  end

  defp post(session_uri, text) do
    msg =
      Message.new(
        Ezagent.URI.entity(:team_alpha, :agent, "anon-access-bot"),
        %{text: text, attachments: []},
        visibility: :external_visible
      )

    {:ok, _} = MessageStore.write(msg, session_uri)
    :ok
  end

  # ----- the membership-gated anon read ----------------------------------

  describe "a minted + joined anon-User reads via membership (membership-only)" do
    test "after session.join, ChatFeed.snapshot/2 AUTHORIZES the anon-User" do
      session = spawn_session()
      post(session, "hello world")

      {:ok, anon} = AnonUser.mint(session)
      :ok = spawn_anon_kind(anon)

      # Before join: a non-member → denied (the gate is real).
      assert {:error, :unauthorized} = ChatFeed.snapshot(session, anon)

      # Join via production dispatch, then the SAME predicate authorizes.
      assert {:ok, _} = join(session, anon)
      assert {:ok, %{messages: msgs}} = ChatFeed.snapshot(session, anon)
      assert Enum.any?(msgs, &(message_text(&1) == "hello world"))
    end
  end

  # ----- cross-session isolation -----------------------------------------

  describe "cross-session isolation — an anon-User reads ONLY its own session" do
    test "an anon-User joined to session A is DENIED reading session B" do
      session_a = spawn_session()
      session_b =
        spawn_session(Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "access-owner-b"))

      {:ok, anon} = AnonUser.mint(session_a)
      :ok = spawn_anon_kind(anon)
      assert {:ok, _} = join(session_a, anon)

      assert {:ok, _} = ChatFeed.snapshot(session_a, anon)
      assert {:error, :unauthorized} = ChatFeed.snapshot(session_b, anon)
    end

    test "the ChatFeedAuth token bound to session A fails verify for session B" do
      session_a = spawn_session()
      session_b =
        spawn_session(Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "access-owner-b2"))

      {:ok, anon} = AnonUser.mint(session_a)

      token = ChatFeedAuth.issue_token(anon, session_a)

      assert {:ok, ^anon} = ChatFeedAuth.verify(token, session_a)
      assert {:error, :unauthorized} = ChatFeedAuth.verify(token, session_b)
    end
  end

  describe "non-member / crafted callers are denied (the gate is byte-unchanged)" do
    test "a never-joined anon-User and a nil/crafted caller are denied" do
      session = spawn_session()
      {:ok, anon} = AnonUser.mint(session)

      assert {:error, :unauthorized} = ChatFeed.snapshot(session, anon)
      assert {:error, :unauthorized} = ChatFeed.snapshot(session, nil)
      assert {:error, :unauthorized} = ChatFeed.snapshot(session, "not-a-uri")
    end
  end

  describe "codex P1 — an anon-User NEVER claims ownership on first-join" do
    alias Ezagent.ActionSet.Session.Membership

    test "anon_member?/1 recognizes the reserved anon naming convention" do
      assert Membership.anon_member?(Ezagent.URI.entity(:team_alpha, :user, "anon-deadbeef"))
      refute Membership.anon_member?(Ezagent.URI.entity(:team_alpha, :user, "real-human"))
      refute Membership.anon_member?(Ezagent.URI.entity(:team_alpha, :agent, "anon-not-a-user"))
      refute Membership.anon_member?(nil)
    end

    test "joining an OWNERLESS session leaves owner_uri nil (no first-join owner claim)" do
      session = spawn_session(nil)
      {:ok, anon} = AnonUser.mint(session)
      spawn_anon_kind(anon)
      {:ok, _} = join(session, anon)

      # The first-join owner fallback is SUPPRESSED for the anon: the session
      # stays ownerless rather than handing the anon owner + the
      # OrchestratorAdmin :restart cap (the codex P1 escalation).
      {:ok, pid} = KindRegistry.lookup(session)
      state = :sys.get_state(pid, 500)
      assert is_nil(state.state.session.state.owner_uri)
    end
  end

  describe "codex P2 — deleting an anon-User clears its Kind snapshot (no resurrection)" do
    test "Users.delete tears down the spawned User Kind state, not just the provisioning row" do
      session = spawn_session()
      {:ok, anon} = AnonUser.mint(session)
      spawn_anon_kind(anon)
      {:ok, _} = join(session, anon)
      # the joined anon User now has durable kind_snapshots state
      anon_str = URI.to_string(anon)
      assert Ezagent.Ecto.KindSnapshot.get(anon_str)

      :ok = Ezagent.Users.delete(anon)

      # both the provisioning row AND the Kind snapshot are gone
      assert is_nil(Ezagent.Ecto.KindSnapshot.get(anon_str))
      assert is_nil(Ezagent.Users.get_by_uri(anon))
    end
  end

  defp message_text(%{body: %{"text" => t}}), do: t
  defp message_text(%{body: %{text: t}}), do: t
  defp message_text(_), do: nil
end
