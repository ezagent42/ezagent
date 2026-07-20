defmodule Ezagent.Socialware.SessionReadsExternalFeedTest do
  @moduledoc """
  Read-plane-authz PR-2 ACCEPTANCE tests — the external-feed plane of the
  `SessionReads` chokepoint (external-visible messages + delivery outbox +
  surface page/shell), with the `public_view` open policy folded IN.

  The BINDING behavioral guarantees (plan Pillar A):

    * **#4** — an anon / signed-in NON-member caller reads a PUBLIC
      (`web_anon_access`) session's feed through the chokepoint policy;
      a private session rejects the same caller with
      `{:error, :unauthorized}` BEFORE any read.
    * **authz-rejection** — a non-member DELIVERY read
      (`external_deliveries_since/3`, `latest_external_delivery_cursor/2`,
      `committed_external_surface_version/2`) and a non-member SURFACE read
      (`external_surface/2`) are REJECTED — the caller-authorizing chokepoint,
      proven by a non-member test (closes finding-#4: the store reads
      themselves now take a caller).
    * **#10** — the feed is BYTE-IDENTICAL for an authorized caller: every
      chokepoint read returns exactly what the pre-consolidation direct
      store/outbox/slice reads returned (message + delivery + surface).
  """
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.ActionSet.Surface
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, SessionTemplate}
  alias Ezagent.{Capability, KindRegistry}

  alias Ezagent.Socialware.{
    DefinitionRegistry,
    DeliveryOutbox,
    ExternalFeed,
    Installation,
    SessionReads,
    Settlement
  }

  alias EzagentCore.Repo

  @workspace "team-alpha"
  @owner Ezagent.URI.entity(:team_alpha, :user, "sr-feed-owner")
  @stranger Ezagent.URI.entity(:team_alpha, :user, "sr-feed-stranger")

  # ----- fixtures ----------------------------------------------------------

  defp spawn_socialware_session do
    uri =
      Ezagent.URI.session(
        :team_alpha,
        :socialware,
        "sr-feed-#{System.unique_integer([:positive])}"
      )

    :ok = KindSnapshot.delete(URI.to_string(uri))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: uri,
        owner_uri: @owner,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))

    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

        :error ->
          :ok
      end
    end)

    uri
  end

  # A live session with a socialware install whose definition declares
  # `web_anon_access` per `flag` (true = public_view, false = private) — the
  # same install machinery `ExternalFeedPublicReadTest` exercises.
  defp session_with_public_view(flag) do
    u = System.unique_integer([:positive])
    name = "sr-feed-def-#{u}"

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(definition(name, flag),
        workspace_uri: Ezagent.URI.workspace(@workspace)
      )

    content = %{name: "sr-feed-tmpl-#{u}", installs: [name]}
    {:ok, tmpl_uri} = SessionTemplate.persist_version_as_system(content, @workspace)

    session_uri = Ezagent.URI.new!("session://#{@workspace}/default/sr-feed-#{u}")

    {:ok, behaviors} =
      Installation.behavior_set_for_template(content, Ezagent.URI.workspace(@workspace))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{uri: session_uri, owner_uri: @owner, behaviors: behaviors})

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    :ok =
      Installation.install_template_installs(
        session_uri,
        Ezagent.URI.workspace(@workspace),
        content,
        @owner
      )

    {:ok, _} =
      ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl_uri})

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

  defp definition(name, web_anon_access) do
    %{
      name: name,
      bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
      shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
      owner_policy: %{type: :installer},
      visibility_policy: %{publish_policy: :auto, web_anon_access: web_anon_access}
    }
  end

  defp write(session_uri, text, visibility) do
    msg =
      Message.new(
        Ezagent.URI.entity(:team_alpha, :agent, "sr-feed-bot"),
        %{text: text, attachments: []},
        visibility: visibility
      )

    {:ok, written} = MessageStore.write(msg, session_uri)
    written
  end

  # Commit a settlement carrying `message_ids` (and optional surface version) so
  # the committed-external-visible message gate + the delivery outbox row exist —
  # the light form of the commit boundary (Settlement.begin + outbox row +
  # mark_committed_for_test assigns the committed_seq).
  defp commit(session_uri, message_ids, surface_version \\ nil) do
    {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(session_uri)
    turn_id = "#{URI.to_string(session_uri)}#turn-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Settlement.begin(%{
        turn_id: turn_id,
        session_uri: session_uri,
        workspace_uri: workspace_uri,
        target_message_ids: message_ids,
        target_surface_version: surface_version,
        expected_prior_approved: nil
      })

    {:ok, _} =
      Repo.insert(%DeliveryOutbox{
        turn_id: turn_id,
        session_uri: URI.to_string(session_uri),
        workspace_uri: URI.to_string(workspace_uri),
        message_ids: message_ids,
        surface_version: surface_version,
        committed_seq: nil,
        emitted_at: DateTime.utc_now()
      })

    {:ok, _} = Settlement.mark_committed_for_test(turn_id)
    turn_id
  end

  # The pre-consolidation direct outbox read ExternalFeed used to make —
  # reproduced verbatim so the chokepoint read can be proven BYTE-IDENTICAL.
  defp direct_deliveries_since(session_uri, cursor) do
    session_str = URI.to_string(session_uri)

    from(o in DeliveryOutbox,
      where:
        o.session_uri == ^session_str and not is_nil(o.committed_seq) and
          o.committed_seq > ^cursor,
      order_by: [asc: o.committed_seq],
      select: %{
        cursor: o.committed_seq,
        turn_id: o.turn_id,
        message_ids: o.message_ids,
        surface_version: o.surface_version
      }
    )
    |> Repo.all()
  end

  # ----- #4 — public-session anon read via the folded chokepoint policy ------

  describe "#4 — a PUBLIC session's feed is readable through the chokepoint policy" do
    test "a signed-in NON-member reads messages + deliveries + surface of a public session" do
      session = session_with_public_view(true)

      assert {:ok, _} = SessionReads.messages(@stranger, session, :external_feed, %{limit: 50})
      assert {:ok, _} = SessionReads.messages(@stranger, session, :external_chat, %{limit: 50})
      assert {:ok, _} = SessionReads.external_deliveries_since(@stranger, session, 0)
      assert {:ok, _} = SessionReads.latest_external_delivery_cursor(@stranger, session)

      assert {:ok, _} = SessionReads.committed_external_surface_version(@stranger, session)
      assert {:ok, _} = SessionReads.external_surface(@stranger, session)
    end

    test "a NIL (anonymous, identity-less) caller reads the public session's feed" do
      session = session_with_public_view(true)

      assert {:ok, _} = SessionReads.messages(nil, session, :external_feed, %{limit: 50})
      assert {:ok, _} = SessionReads.external_deliveries_since(nil, session, 0)
      assert {:ok, _} = SessionReads.external_surface(nil, session)
    end

    test "the public open policy does NOT widen the strict internal conversation read" do
      session = session_with_public_view(true)

      # The public-view fold applies ONLY to the external-feed plane: the strict
      # conversation/member reads keep rejecting a non-member (the PR-1 deep-link
      # fix is not regressed by the open page gate).
      assert {:error, :unauthorized} =
               SessionReads.messages(@stranger, session, :conversation, %{limit: 50})

      assert {:error, :unauthorized} =
               SessionReads.messages(@stranger, session, :chat_feed, %{limit: 50})

      assert {:error, :unauthorized} = SessionReads.members(@stranger, session)
      refute SessionReads.authorized?(@stranger, session)
    end
  end

  # ----- authz-rejection — non-member non-public reads are REJECTED ----------

  describe "authz-rejection — a non-member is rejected BEFORE any feed/delivery/surface read" do
    test "message views reject a non-member on a private session" do
      session = spawn_socialware_session()
      write(session, "secret", :external_visible)

      assert {:error, :unauthorized} =
               SessionReads.messages(@stranger, session, :external_feed, %{limit: 50})

      assert {:error, :unauthorized} =
               SessionReads.messages(@stranger, session, :external_feed, %{ids: ["any"]})

      assert {:error, :unauthorized} =
               SessionReads.messages(@stranger, session, :external_chat, %{limit: 50})
    end

    test "delivery reads reject a non-member on a private session (finding-#4)" do
      session = spawn_socialware_session()
      msg = write(session, "delivered", :external_visible)
      _turn = commit(session, [msg.id], 1)

      assert {:error, :unauthorized} =
               SessionReads.external_deliveries_since(@stranger, session, 0)

      assert {:error, :unauthorized} =
               SessionReads.latest_external_delivery_cursor(@stranger, session)

      assert {:error, :unauthorized} =
               SessionReads.committed_external_surface_version(@stranger, session)
    end

    test "the surface read rejects a non-member on a private session (finding-#4)" do
      session = spawn_socialware_session()

      assert {:error, :unauthorized} = SessionReads.external_surface(@stranger, session)
      assert {:error, :unauthorized} = SessionReads.external_surface(nil, session)
    end

    test "ExternalFeed's public API rejects the non-member end-to-end" do
      session = spawn_socialware_session()

      assert {:error, :unauthorized} = ExternalFeed.snapshot(session, @stranger)
      assert {:error, :unauthorized} = ExternalFeed.history(session, @stranger)
      assert {:error, :unauthorized} = ExternalFeed.chat_messages(session, @stranger)
      assert {:error, :unauthorized} = ExternalFeed.join(session, @stranger)
      assert {:error, :unauthorized} = ExternalFeed.replay(session, @stranger, 0)

      assert {:error, :unauthorized} =
               ExternalFeed.committed_deliveries_since(@stranger, session, 0)

      assert {:error, :unauthorized} = ExternalFeed.latest_cursor(@stranger, session)
      refute ExternalFeed.member?(session, @stranger)
    end
  end

  # ----- #10 — the feed is BYTE-IDENTICAL for an authorized caller -----------

  describe "#10 — byte-identical feed for an authorized caller (post-consolidation parity)" do
    test "message views return exactly the pre-consolidation direct store reads" do
      session = spawn_socialware_session()
      public_msg = write(session, "public", :external_visible)
      internal_msg = write(session, "internal", :external_visible)
      {:ok, _} = MessageStore.mark_visibility([internal_msg.id], :internal)
      _turn = commit(session, [public_msg.id, internal_msg.id])

      # :external_feed window — == committed_external_visible/2 verbatim.
      assert {:ok, via_chokepoint} =
               SessionReads.messages(@owner, session, :external_feed, %{limit: 50})

      assert via_chokepoint == MessageStore.committed_external_visible(session, 50)
      assert Enum.map(via_chokepoint, & &1.id) == [public_msg.id]

      # :external_feed by-ids — == committed_external_visible_by_ids/2 verbatim.
      ids = [public_msg.id, internal_msg.id]

      assert {:ok, by_ids} = SessionReads.messages(@owner, session, :external_feed, %{ids: ids})
      assert by_ids == MessageStore.committed_external_visible_by_ids(session, ids)
      assert Enum.map(by_ids, & &1.id) == [public_msg.id]

      # :external_chat — == chat_visible_recent/2 verbatim (sees every
      # external_visible message, committed or not).
      assert {:ok, chat} = SessionReads.messages(@owner, session, :external_chat, %{limit: 50})
      assert chat == MessageStore.chat_visible_recent(session, 50)
    end

    test "delivery + surface reads return exactly the pre-consolidation direct reads" do
      session = spawn_socialware_session()
      msg = write(session, "delivered", :external_visible)
      turn_id = commit(session, [msg.id], 1)

      # Delivery replay — byte-identical to the pre-consolidation outbox query.
      assert {:ok, deliveries} = SessionReads.external_deliveries_since(@owner, session, 0)
      assert deliveries == direct_deliveries_since(session, 0)
      assert [%{cursor: 1, turn_id: ^turn_id, message_ids: [_], surface_version: 1}] = deliveries

      assert SessionReads.latest_external_delivery_cursor(@owner, session) == {:ok, 1}
      assert SessionReads.committed_external_surface_version(@owner, session) == {:ok, 1}

      # The surface read — byte-identical to the live :surface slice read
      # ExternalFeed made pre-consolidation.
      {:ok, live_surface} = Ezagent.Kind.get_slice(session, :surface)

      assert {:ok, surface} = SessionReads.external_surface(@owner, session)
      assert surface == live_surface
    end

    test "ExternalFeed.snapshot/2 renders exactly the manually-computed feed (messages + delivery + surface)" do
      session = spawn_socialware_session()
      msg = write(session, "delivered", :external_visible)
      _turn = commit(session, [msg.id], 1)

      {:ok, live_surface} = Ezagent.Kind.get_slice(session, :surface)

      expected = %{
        messages: MessageStore.committed_external_visible(session, 100),
        page: Surface.tree_for_version(live_surface, 1),
        shell: nil,
        shell_css: nil
      }

      assert {:ok, snapshot} = ExternalFeed.snapshot(session, @owner)
      assert snapshot == expected
      assert expected.messages != []
    end
  end
end
