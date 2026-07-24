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
  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "sr-feed-owner")
  defp stranger, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "sr-feed-stranger")

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
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: uri,
        owner_uri: owner(),
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
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session_uri,
        owner_uri: owner(),
        behaviors: behaviors
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    :ok =
      Installation.install_template_installs(
        session_uri,
        Ezagent.URI.workspace(@workspace),
        content,
        owner()
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

  # Prepare a settlement WITHOUT committing it (the pre-commit half of commit/3):
  # settlement begun + outbox row with committed_seq NIL. Returns the turn_id so a
  # test can fire the atomic commit (mark_committed_for_test/1) at a chosen instant.
  defp prepare_uncommitted(session_uri, message_ids, surface_version) do
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

      assert {:ok, _} = SessionReads.messages(stranger(), session, :external_feed, %{limit: 50})
      assert {:ok, _} = SessionReads.messages(stranger(), session, :external_chat, %{limit: 50})
      assert {:ok, _} = SessionReads.external_deliveries_since(stranger(), session, 0)
      assert {:ok, _} = SessionReads.latest_external_delivery_cursor(stranger(), session)

      assert {:ok, _} = SessionReads.committed_external_surface_version(stranger(), session)
      assert {:ok, _} = SessionReads.external_surface(stranger(), session)
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
               SessionReads.messages(stranger(), session, :conversation, %{limit: 50})

      assert {:error, :unauthorized} =
               SessionReads.messages(stranger(), session, :chat_feed, %{limit: 50})

      assert {:error, :unauthorized} = SessionReads.members(stranger(), session)
      refute SessionReads.authorized?(stranger(), session)
    end
  end

  # ----- authz-rejection — non-member non-public reads are REJECTED ----------

  describe "authz-rejection — a non-member is rejected BEFORE any feed/delivery/surface read" do
    test "message views reject a non-member on a private session" do
      session = spawn_socialware_session()
      write(session, "secret", :external_visible)

      assert {:error, :unauthorized} =
               SessionReads.messages(stranger(), session, :external_feed, %{limit: 50})

      assert {:error, :unauthorized} =
               SessionReads.messages(stranger(), session, :external_feed, %{ids: ["any"]})

      assert {:error, :unauthorized} =
               SessionReads.messages(stranger(), session, :external_chat, %{limit: 50})
    end

    test "delivery reads reject a non-member on a private session (finding-#4)" do
      session = spawn_socialware_session()
      msg = write(session, "delivered", :external_visible)
      _turn = commit(session, [msg.id], 1)

      assert {:error, :unauthorized} =
               SessionReads.external_deliveries_since(stranger(), session, 0)

      assert {:error, :unauthorized} =
               SessionReads.latest_external_delivery_cursor(stranger(), session)

      assert {:error, :unauthorized} =
               SessionReads.committed_external_surface_version(stranger(), session)
    end

    test "the surface read rejects a non-member on a private session (finding-#4)" do
      session = spawn_socialware_session()

      assert {:error, :unauthorized} = SessionReads.external_surface(stranger(), session)
      assert {:error, :unauthorized} = SessionReads.external_surface(nil, session)
    end

    test "ExternalFeed's public API rejects the non-member end-to-end" do
      session = spawn_socialware_session()

      assert {:error, :unauthorized} = ExternalFeed.snapshot(session, stranger())
      assert {:error, :unauthorized} = ExternalFeed.history(session, stranger())
      assert {:error, :unauthorized} = ExternalFeed.chat_messages(session, stranger())
      assert {:error, :unauthorized} = ExternalFeed.join(session, stranger())
      assert {:error, :unauthorized} = ExternalFeed.replay(session, stranger(), 0)

      assert {:error, :unauthorized} =
               ExternalFeed.committed_deliveries_since(stranger(), session, 0)

      assert {:error, :unauthorized} = ExternalFeed.latest_cursor(stranger(), session)
      refute ExternalFeed.member?(session, stranger())
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
               SessionReads.messages(owner(), session, :external_feed, %{limit: 50})

      assert via_chokepoint == MessageStore.committed_external_visible(session, 50)
      assert Enum.map(via_chokepoint, & &1.id) == [public_msg.id]

      # :external_feed by-ids — == committed_external_visible_by_ids/2 verbatim.
      ids = [public_msg.id, internal_msg.id]

      assert {:ok, by_ids} = SessionReads.messages(owner(), session, :external_feed, %{ids: ids})
      assert by_ids == MessageStore.committed_external_visible_by_ids(session, ids)
      assert Enum.map(by_ids, & &1.id) == [public_msg.id]

      # :external_chat — == chat_visible_recent/2 verbatim (sees every
      # external_visible message, committed or not).
      assert {:ok, chat} = SessionReads.messages(owner(), session, :external_chat, %{limit: 50})
      assert chat == MessageStore.chat_visible_recent(session, 50)
    end

    test "delivery + surface reads return exactly the pre-consolidation direct reads" do
      session = spawn_socialware_session()
      msg = write(session, "delivered", :external_visible)
      turn_id = commit(session, [msg.id], 1)

      # Delivery replay — byte-identical to the pre-consolidation outbox query.
      assert {:ok, deliveries} = SessionReads.external_deliveries_since(owner(), session, 0)
      assert deliveries == direct_deliveries_since(session, 0)
      assert [%{cursor: 1, turn_id: ^turn_id, message_ids: [_], surface_version: 1}] = deliveries

      assert SessionReads.latest_external_delivery_cursor(owner(), session) == {:ok, 1}
      assert SessionReads.committed_external_surface_version(owner(), session) == {:ok, 1}

      # The surface read — byte-identical to the live :surface slice read
      # ExternalFeed made pre-consolidation.
      {:ok, live_surface} = Ezagent.Kind.get_slice(session, :surface)

      assert {:ok, surface} = SessionReads.external_surface(owner(), session)
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

      assert {:ok, snapshot} = ExternalFeed.snapshot(session, owner())
      assert snapshot == expected
      assert expected.messages != []
    end
  end

  # ----- snapshot straddle consistency (read-plane hardening §a) --------------

  describe "snapshot straddle consistency — a mid-read commit never yields page-without-messages" do
    test "external_snapshot_reads/3 is self-consistent when a settlement commits between its reads" do
      session = spawn_socialware_session()
      msg = write(session, "delivered", :external_visible)
      turn_id = prepare_uncommitted(session, [msg.id], 1)

      # Pre-commit sanity: nothing committed yet.
      assert MessageStore.committed_external_visible(session, 100) == []
      assert SessionReads.committed_external_surface_version(owner(), session) == {:ok, nil}

      # The mid-read seam fires the atomic commit in the straddle window.
      seam = fn -> {:ok, _} = Settlement.mark_committed_for_test(turn_id) end

      assert {:ok, %{messages: messages, version: version}} =
               SessionReads.external_snapshot_reads(owner(), session, mid_read: seam)

      # SELF-CONSISTENCY INVARIANT: if the snapshot reports a committed page
      # version, the committed turn's messages MUST be present (no page-without-
      # content straddle). The benign direction (messages present, version still
      # nil) is allowed — it self-heals on the next poll.
      if version != nil do
        assert Enum.any?(messages, &(&1.id == msg.id)),
               "straddle: reported committed version #{inspect(version)} but its messages are missing"
      end
    end
  end

  # ----- C2 seed (c) — cold surface renders via the §2.2 read surface ---------

  describe "C2 seed (c) — the surface renders via the §2.2 read surface, not StateRebuilder" do
    # `surface_slice/1` is now `Kind.read/3` (live or lazy-rehydrate) with a
    # `Kind.read_durable/3` fallback — the §2.2-sanctioned replacement for the old
    # hand-rolled `StateRebuilder.rebuild/1` durable rehydrate. The behavioral crux
    # is that the committed surface is served from the DURABLE row regardless of
    # process liveness; `read_durable/3` is process-INDEPENDENT (never a GenServer
    # call), so it is the deterministic, race-free way to pin that — including AFTER
    # the process dies. (external_surface's own membership authz is live-only C7
    # debt, out of C2 scope, so this test targets the migrated surface read.)
    test "the committed surface is durable and read_durable serves it before AND after the process dies" do
      session = spawn_socialware_session()
      msg = write(session, "delivered", :external_visible)
      _turn = commit(session, [msg.id], 1)

      # The LIVE surface — the committed page the migrated read must reproduce.
      {:ok, live_surface} = Ezagent.Kind.get_slice(session, :surface)

      # LIVE: the live chokepoint returns the committed surface (post-migration
      # parity — surface_slice's read/3 live path == the pre-migration get_slice).
      assert {:ok, ^live_surface} = SessionReads.external_surface(owner(), session)

      # LIVE: the durable projection == the live slice (single/live agree by
      # construction) — so surface_slice's read_durable fallback renders the same page.
      assert {:ok, ^live_surface, _meta} = Ezagent.Kind.read_durable(session, :surface)

      # COLD: kill the process (a BEAM-restart / reap surrogate). The durable row
      # survives; `read_durable/3` still serves the committed surface — the exact
      # fallback surface_slice takes when read/3 cannot serve a cold session,
      # WITHOUT reaching into the framework's StateRebuilder internals.
      {:ok, pid} = KindRegistry.lookup(session)

      :ok =
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          pid
        )

      assert {:ok, ^live_surface, _meta} = Ezagent.Kind.read_durable(session, :surface)
    end

    test "the REAL C2 caller (external_surface → surface_slice) renders a COLD session's page" do
      # A PUBLIC session so the read gate is open (web_anon_access) even cold — this
      # lets us drive the ACTUAL migrated caller (external_surface → surface_slice →
      # Kind.read/3) in a cold state, not just the read primitive.
      session = session_with_public_view(true)
      msg = write(session, "delivered", :external_visible)
      _turn = commit(session, [msg.id], 1)

      {:ok, live_surface} = Ezagent.Kind.get_slice(session, :surface)

      # Take the session COLD and WAIT for its process to fully die (a BEAM-restart
      # / reap surrogate) — no racy "stays de-registered" assumption.
      {:ok, pid} = KindRegistry.lookup(session)
      ref = Process.monitor(pid)

      :ok =
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          pid
        )

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      # The migrated caller renders the committed page from the cold session:
      # surface_slice's `Kind.read/3` lazy-rehydrates from the durable snapshot (and
      # its `read_durable/3` fallback covers any mid-restart :noproc window) — WITHOUT
      # reaching into the framework's StateRebuilder internals.
      assert {:ok, ^live_surface} = SessionReads.external_surface(nil, session)
    end

    test "session_reads.ex holds no StateRebuilder reach-in (acceptance 3(c))" do
      src =
        File.read!(
          Path.join(
            Ezagent.ActorBoundaryScanner.repo_root(),
            "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex"
          )
        )

      refute src =~ "StateRebuilder",
             "acceptance 3(c): session_reads.ex must not reference the framework StateRebuilder"
    end
  end
end
