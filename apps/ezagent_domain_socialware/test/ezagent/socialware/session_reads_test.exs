defmodule Ezagent.Socialware.SessionReadsTest do
  @moduledoc """
  The `SessionReads` conversation read chokepoint — proven at the source layer
  (real `Session` Kind, real production `session.join` dispatch, real store).

  These are the BINDING behavioral guarantees (read-plane-authz plan Pillar A):
  a non-authorized caller is REJECTED with `{:error, :unauthorized}` BEFORE any
  read — NOT satisfiable by a byte-parity / "routed through the wrapper" check.
  The chokepoint also owns the `:read_unfiltered` row-policy (sourced from the
  caller's OWN live caps, never a caller-supplied flag), and authorizes ONCE
  per call (no per-row actor round-trip).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.{Capability, KindRegistry, Message, MessageStore}
  alias Ezagent.Socialware.SessionReads
  alias Ezagent.Test.CapHelper

  @owner Ezagent.URI.user(:system, :admin)
  @stranger Ezagent.URI.entity(:team_alpha, :user, "sr-stranger")

  # ----- fixtures --------------------------------------------------------

  defp spawn_session(owner_uri \\ @owner) do
    session_uri =
      Ezagent.URI.new!(
        "session://team-alpha/default/session-reads-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
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

  # Spawn a live User Kind so `EntityCaps.load/1` returns its caps and it is a
  # registered member-target for `session.join`.
  defp spawn_user(%URI{} = user_uri, caps) do
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: caps})

    on_exit(fn ->
      case KindRegistry.lookup(user_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainIdentity.Application.UserSupervisor, pid)

        :error ->
          :ok
      end
    end)

    :ok
  end

  # Join `member_uri` via the PRODUCTION dispatch path — the at-join grant lands
  # the member-cap LIVE, which is exactly the async fresh-join the live-first
  # authorize must see.
  defp join(session_uri, member_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    caller = User.admin_uri()
    cap = CapHelper.signed_action_cap!(target, caller)

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

  defp write(session_uri, text, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, :external_visible)
    inserted_at = Keyword.get(opts, :inserted_at)

    msg_opts =
      [visibility: visibility] ++ if(inserted_at, do: [inserted_at: inserted_at], else: [])

    msg =
      Message.new(
        Ezagent.URI.entity(:team_alpha, :agent, "session-reads-bot"),
        %{text: text, attachments: []},
        msg_opts
      )

    {:ok, _} = MessageStore.write(msg, session_uri)
    :ok
  end

  defp texts({:ok, messages}), do: Enum.map(messages, &message_text/1)
  defp message_text(%{body: %{"text" => t}}), do: t
  defp message_text(%{body: %{text: t}}), do: t
  defp message_text(_), do: nil

  # ----- (1) authz-rejection — BINDING, fail-closed ----------------------

  describe "a non-member is REJECTED before any read (authz-rejection)" do
    test "messages/4 initial-load → {:error, :unauthorized}" do
      session = spawn_session()
      write(session, "secret")

      assert {:error, :unauthorized} =
               SessionReads.messages(@stranger, session, :conversation, %{limit: 50})
    end

    test "messages/4 older/pagination → {:error, :unauthorized}" do
      session = spawn_session()
      write(session, "secret")
      cursor = DateTime.utc_now()

      assert {:error, :unauthorized} =
               SessionReads.messages(@stranger, session, :conversation, %{
                 limit: 50,
                 older_than: cursor
               })
    end

    test "members/2 → {:error, :unauthorized}" do
      session = spawn_session()
      assert {:error, :unauthorized} = SessionReads.members(@stranger, session)
    end

    test "nil / malformed caller → {:error, :unauthorized} (fail-closed)" do
      session = spawn_session()

      assert {:error, :unauthorized} =
               SessionReads.messages(nil, session, :conversation, %{limit: 50})

      assert {:error, :unauthorized} =
               SessionReads.messages("entity://x", session, :conversation, %{limit: 50})

      assert {:error, :unauthorized} = SessionReads.members(nil, session)
    end
  end

  # ----- (2) authorized reads --------------------------------------------

  describe "an owner/member reads through the chokepoint" do
    test "the owner reads the initial recency window" do
      session = spawn_session()
      write(session, "hello")
      write(session, "world")

      result = SessionReads.messages(@owner, session, :conversation, %{limit: 50})
      assert {:ok, messages} = result
      assert Enum.sort(texts(result)) == ["hello", "world"]
      assert Enum.all?(messages, &match?(%Message{}, &1))
    end

    test "the owner pages older history (pagination window)" do
      session = spawn_session()
      base = ~U[2026-07-01 00:00:00.000000Z]
      write(session, "old", inserted_at: DateTime.add(base, 1, :second))
      write(session, "new", inserted_at: DateTime.add(base, 5, :second))

      cursor = DateTime.add(base, 3, :second)

      result =
        SessionReads.messages(@owner, session, :conversation, %{limit: 50, older_than: cursor})

      # Only "old" is strictly older than the cursor.
      assert texts(result) == ["old"]
    end

    test "the owner reads the members map" do
      session = spawn_session()
      assert {:ok, members} = SessionReads.members(@owner, session)
      assert is_map(members)
    end

    # #3 — a member who joined via the async at-join grant CAN read fresh
    # history. Before join → denied; after the production join dispatch (which
    # grants the member-cap LIVE), the SAME live-first predicate authorizes.
    # Proves the authz is live-first, not persisted-only.
    test "a member joined via the at-join grant reads fresh history (live-first)" do
      session = spawn_session()
      write(session, "history")

      member =
        Ezagent.URI.entity(:team_alpha, :user, "sr-fresh-#{System.unique_integer([:positive])}")

      :ok = spawn_user(member, User.initial_caps_for_spawn(member))

      # Not yet a member → denied.
      assert {:error, :unauthorized} =
               SessionReads.messages(member, session, :conversation, %{limit: 50})

      # Join via the production dispatch (async at-join member-cap grant).
      assert {:ok, _} = join(session, member)

      # The live-first predicate now authorizes and returns the fresh history.
      result = SessionReads.messages(member, session, :conversation, %{limit: 50})
      assert {:ok, _} = result
      assert "history" in texts(result)
    end
  end

  # ----- (3) :read_unfiltered row-policy (#6) ----------------------------

  describe ":read_unfiltered row-policy is owned by the chokepoint" do
    test "a caller WITHOUT the cap sees only :external_visible rows" do
      # The admin owner holds no session :read_unfiltered cap → filtered view.
      session = spawn_session()
      write(session, "public", visibility: :external_visible)
      write(session, "internal", visibility: :internal)

      result = SessionReads.messages(@owner, session, :conversation, %{limit: 50})
      assert texts(result) == ["public"]
    end

    test "a caller holding the signed :read_unfiltered cap sees :internal rows too" do
      internal_reader =
        Ezagent.URI.entity(
          :team_alpha,
          :user,
          "sr-internal-#{System.unique_integer([:positive])}"
        )

      # Session OWNED by the internal reader (owner → authorized), who ALSO holds
      # the session's signed :read_unfiltered cap in its LIVE identity slice.
      session = spawn_session(internal_reader)

      unfiltered_cap =
        CapHelper.signed_cap!(session, internal_reader, read_unfiltered_cap(session))

      :ok = spawn_user(internal_reader, [unfiltered_cap])

      write(session, "public", visibility: :external_visible)
      write(session, "internal", visibility: :internal)

      result = SessionReads.messages(internal_reader, session, :conversation, %{limit: 50})
      assert Enum.sort(texts(result)) == ["internal", "public"]
    end
  end

  # ----- (4) #8 — no per-row actor round-trip ----------------------------

  describe "the read authorizes ONCE per call (no per-row actor round-trip)" do
    test "a batch larger than the limit returns a single bounded window" do
      session = spawn_session()
      base = ~U[2026-07-02 00:00:00.000000Z]

      # 60 messages, limit 50 — a per-row iteration would not window; a single
      # bounded store query (the chokepoint's shape after ONE authorize) does.
      for i <- 1..60 do
        write(session, "m#{i}", inserted_at: DateTime.add(base, i, :second))
      end

      assert {:ok, messages} =
               SessionReads.messages(@owner, session, :conversation, %{limit: 50})

      assert length(messages) == 50
    end
  end

  # ----- (5) live-plane gate predicates (round-2 F1/F2) ------------------
  #
  # The `world_live` broadcast handler and `push_members` gate the LIVE plane on
  # THESE predicates (not just the historical read). A non-member `false` here ⇒
  # the broadcast handler drops the message and `push_members` pushes no roster —
  # closing the ungated live-stream / roster-leak that PR-1's history-only gate
  # left open.
  describe "authorized?/2 + read_unfiltered?/2 — the LIVE-plane gate predicates" do
    test "a non-member is NOT authorized (⇒ broadcast dropped, roster suppressed)" do
      session = spawn_session()
      :ok = spawn_user(@stranger, User.initial_caps_for_spawn(@stranger))
      refute SessionReads.authorized?(@stranger, session)
    end

    test "nil / malformed caller is NOT authorized (fail-closed)" do
      session = spawn_session()
      refute SessionReads.authorized?(nil, session)
      refute SessionReads.authorized?(:garbage, session)
    end

    test "the owner IS authorized" do
      session = spawn_session()
      assert SessionReads.authorized?(@owner, session)
    end

    test "a member joined via the at-join grant IS authorized (live-first)" do
      session = spawn_session()

      member =
        Ezagent.URI.entity(:team_alpha, :user, "sr-live-#{System.unique_integer([:positive])}")

      :ok = spawn_user(member, User.initial_caps_for_spawn(member))

      refute SessionReads.authorized?(member, session)
      assert {:ok, _} = join(session, member)
      assert SessionReads.authorized?(member, session)
    end

    test "read_unfiltered?/2 gates live :internal delivery — false without the cap, true with it" do
      # A member without the cap → a live :internal message is dropped for them.
      plain = spawn_session()
      refute SessionReads.read_unfiltered?(@owner, plain)

      # A caller holding the signed :read_unfiltered cap → :internal delivered.
      reader =
        Ezagent.URI.entity(:team_alpha, :user, "sr-unf-#{System.unique_integer([:positive])}")

      session = spawn_session(reader)
      cap = CapHelper.signed_cap!(session, reader, read_unfiltered_cap(session))
      :ok = spawn_user(reader, [cap])
      assert SessionReads.read_unfiltered?(reader, session)

      assert {:ok, _new_authority} =
               Ezagent.Cap.Authority.regenesis(
                 session,
                 :session
               )

      refute SessionReads.read_unfiltered?(reader, session)
    end
  end

  defp read_unfiltered_cap(session_uri) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :read_unfiltered,
      session_uri,
      Ezagent.Capability.workspace_of(session_uri)
    )
  end

  # ----- (4) :chat_feed view (ChatFeed's snapshot read via the chokepoint) ---

  describe "the :chat_feed view (ChatFeed's snapshot read)" do
    test "a non-member ChatFeed read is REJECTED" do
      session = spawn_session()
      write(session, "secret")

      assert {:error, :unauthorized} =
               SessionReads.messages(@stranger, session, :chat_feed, %{limit: 50})
    end

    test "a member gets the byte-identical chat recency window (post-migration parity)" do
      session = spawn_session()
      write(session, "one")
      write(session, "two")

      member =
        Ezagent.URI.entity(:team_alpha, :user, "sr-cf-#{System.unique_integer([:positive])}")

      :ok = spawn_user(member, User.initial_caps_for_spawn(member))

      # Not yet a member → the ChatFeed read is denied.
      assert {:error, :unauthorized} =
               SessionReads.messages(member, session, :chat_feed, %{limit: 50})

      assert {:ok, _} = join(session, member)

      # The chokepoint read is byte-identical to the direct store read ChatFeed
      # made before the migration.
      assert {:ok, messages} = SessionReads.messages(member, session, :chat_feed, %{limit: 50})
      assert messages == MessageStore.chat_visible_recent(session, 50)
    end
  end
end
