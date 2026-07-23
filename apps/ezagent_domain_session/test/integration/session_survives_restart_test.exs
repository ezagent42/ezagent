defmodule EzagentDomainInstanceMessage.Integration.SessionSurvivesRestartTest do
  @moduledoc """
  Invariant test for Allen's V1 acceptance feedback (2026-05-22).

  Adding an agent (cc_demo) to a session at runtime, then a phx
  restart, wiped it from `members`. Root cause:
  `Ezagent.Entity.Session.persistence/0` was `:ephemeral` — the
  Session Kind's Chat slice (members / last_seen) was never
  snapshotted, so any restart lost every runtime mutation.

  This test pins the fix: `persistence/0` is now
  `{:snapshot, :on_change}`. It drives the production path —
  `chat.join` dispatch mutates the Session's Chat slice,
  `Ezagent.Kind.Server` snapshots it on change, and a stop + respawn
  of the Session Kind rehydrates the member from `kind_snapshots`.

  Per memory `feedback_completion_requires_invariant_test`: this test
  fails if `persistence/0` ever regresses to `:ephemeral` — the
  respawned session would come back with an empty members map.

  ## Fixtures MUST use the canonical chokepoint `Ezagent.URI.new!/1`

  Task #111 (2026-05-29) — these fixtures previously built URIs via
  stdlib `URI.parse/1`, which sets the deprecated RFC-2396 `:authority`
  field (`authority: "user"`). Production constructs every URI through
  `Ezagent.URI.new!/1` (RFC-3986, `authority: nil`) per SPEC
  `2026-05-27-uri-canonicalization` §3.1, and the snapshot reload path
  re-canonicalizes every embedded `%URI{}` via
  `Ezagent.Kind.Snapshot.canonicalize_uris/1` → `Ezagent.URI.new!/1`.

  A member URI is a MAP KEY in the `:members` slice. An authority-
  bearing fixture key is struct-UNEQUAL to its authority-nil reloaded
  peer even though both `URI.to_string/1` identically — so
  `Map.has_key?(members_after, member_uri)` missed after restart. The
  fix is to build fixtures the way production does: through the
  canonical chokepoint. Do NOT reintroduce stdlib `URI.parse/1` here.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Kind.Snapshot
  alias Ezagent.Test.SnapshotFixtures

  # `chat.join` requires the member's Kind alive in KindRegistry; spawn
  # a real User Kind to act as the runtime-added member, mirroring the
  # production "add an agent to a session" flow.
  defp spawn_member do
    member_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/restart-member-#{System.unique_integer([:positive])}"
      )

    {:ok, _row} = Ezagent.Users.create(member_uri, "pw-not-secret", [])

    {:ok, member_pid} =
      Ezagent.Kind.spawn(User, %{uri: member_uri, initial_caps: MapSet.new()})

    on_exit(fn ->
      if Process.alive?(member_pid) do
        DynamicSupervisor.terminate_child(
          EzagentDomainIdentity.Application.UserSupervisor,
          member_pid
        )
      end
    end)

    member_uri
  end

  defp spawn_session(session_uri) do
    {:ok, pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    # Mirror the production `session` spawn fn: bind the workspace cache.
    :ok =
      Ezagent.WorkspaceRegistry.bind(
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    pid
  end

  defp join(session_uri, member_uri) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp list_members(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    wrapper = :sys.get_state(pid)
    # Lifecycle migration (SPEC 2026-05-29 §2.3C): the `:chat` slice is now
    # the two-container `%{state, transients}` shape; `members` lives in
    # `:state`. (`:monitors` moved to `:transients` — rebuilt by activate/2.)
    chat_slice = Map.get(wrapper.state, :session, %{})
    chat_state = Map.get(chat_slice, :state, chat_slice)
    Map.get(chat_state, :members, %{})
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  describe "session membership survives a Kind restart — THE GATE" do
    test "a member added at runtime is still present after stop + respawn" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/restart-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(session_uri)

      # Clean slate — no stale snapshot from a prior run.
      :ok = KindSnapshot.delete(uri_str)

      member_uri = spawn_member()

      # 1. Spawn the Session Kind.
      pid1 = spawn_session(session_uri)

      # 2. Add the member at runtime via the production chat.join path.
      assert {:ok, %{status: :granted, member: ^member_uri}} = join(session_uri, member_uri)
      wait_until(fn -> Map.has_key?(list_members(session_uri), member_uri) end)

      # 3. The :on_change snapshot must have been written to kind_snapshots.
      wait_until(fn -> not is_nil(KindSnapshot.get(uri_str)) end)
      assert %KindSnapshot{kind_type: "session"} = KindSnapshot.get(uri_str)

      # 4. Simulate a phx restart: stop the Session Kind process.
      :ok =
        DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid1)

      wait_until(fn -> KindRegistry.lookup(session_uri) == :error end)

      # 5. Re-spawn the Session Kind under the SAME URI.
      pid2 = spawn_session(session_uri)
      refute pid1 == pid2

      # 6. The member must be rehydrated from the snapshot — this is the
      #    bug Allen hit: pre-fix, `members` came back empty.
      members_after = list_members(session_uri)

      assert Map.has_key?(members_after, member_uri),
             "session member #{URI.to_string(member_uri)} was lost across restart — " <>
               "Ezagent.Entity.Session.persistence/0 must be {:snapshot, :on_change}"
    end

    test "a fresh session with no prior snapshot starts with empty members" do
      # Guards against the inverse failure: the snapshot load path must
      # not resurrect membership from an unrelated/stale snapshot.
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/fresh-#{System.unique_integer([:positive])}"
        )

      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      _pid = spawn_session(session_uri)

      assert list_members(session_uri) == %{}
    end
  end

  describe "WorkspaceRegistry rebind on rehydrate (invariant 4)" do
    test "respawning a session re-establishes its workspace binding" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/ws-rebind-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(session_uri)
      :ok = KindSnapshot.delete(uri_str)

      member_uri = spawn_member()

      # Spawn via the production `session` SpawnRegistry fn — this is the
      # path that runs `bind_session_workspace/1`.
      {:ok, pid1} = Ezagent.SpawnRegistry.spawn(session_uri)

      # The session URI is `session://team-alpha/default/...` — the
      # workspace segment is the SECOND authority segment (`team-alpha`),
      # NOT the template-axis segment (`default`). `workspace_of/1`
      # extracts `workspace://team-alpha`. (Prior assertion of
      # `host: "default"` was a fixture bug — it confused the
      # template-axis segment with the workspace segment; SPEC v3 §3.6.)
      assert {:ok, %URI{scheme: "workspace", host: "team-alpha"}} =
               Ezagent.WorkspaceRegistry.lookup(session_uri)

      {:ok, _} = join(session_uri, member_uri)
      wait_until(fn -> Map.has_key?(list_members(session_uri), member_uri) end)
      wait_until(fn -> not is_nil(KindSnapshot.get(uri_str)) end)

      # Drop the Kind AND the ETS binding — simulating a phx restart
      # where ETS (in-memory) is wiped but the snapshot row survives.
      :ok =
        DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid1)

      wait_until(fn -> KindRegistry.lookup(session_uri) == :error end)
      :ok = Ezagent.WorkspaceRegistry.unbind(session_uri)
      assert :error = Ezagent.WorkspaceRegistry.lookup(session_uri)

      # Lazy demand-spawn via SpawnRegistry (the rehydrate path) must
      # rebind the workspace from the 3-segment URI.
      {:ok, _pid2} = Ezagent.SpawnRegistry.spawn(session_uri)

      assert {:ok, %URI{scheme: "workspace", host: "team-alpha"}} =
               Ezagent.WorkspaceRegistry.lookup(session_uri),
             "rehydrated session lost its WorkspaceRegistry binding — " <>
               "the `session` spawn fn must rebind from the URI"

      # And the snapshotted member is still there.
      assert Map.has_key?(list_members(session_uri), member_uri)
    end
  end

  describe "Snapshot.load_or_init for Session Kind" do
    test "a Session snapshot round-trips its Chat slice (other behaviors get fresh init per Q5 merge)" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/load-init-#{System.unique_integer([:positive])}"
        )

      member =
        Ezagent.URI.new!("entity://team-alpha/user/m-#{System.unique_integer([:positive])}")

      # Old-shape snapshot (chat slice only — pre-PR-EM-0 Session had
      # only [Chat] in behaviors/0). Saved verbatim to simulate a
      # snapshot taken before PR-EM-0 landed.
      chat_only_slice = %{
        session: %{members: %{member => %{online: true}}, monitors: %{}, last_seen: %{}},
        # P5-0b: Session requires an explicit :kind_base (a backfilled legacy
        # row carries it). Without it the scoped guard fails the reload loud.
        kind_base: %{state: %{behaviors: Session.behaviors()}, transients: %{}}
      }

      :ok = SnapshotFixtures.save_kind_snapshot(session_uri, Session, chat_only_slice)

      loaded = Snapshot.load_or_init(session_uri, Session, %{uri: session_uri})

      # T4 (Lifecycle Phase B foundation): `Behavior.Session` is now a
      # `use Ezagent.Lifecycle` behavior, so `init_fresh` carries `:chat`
      # as the two-container `%{state, transients}` shape. A LEGACY FLAT
      # snapshot slice is coerced on load to `%{state: flat, transients:
      # %{}}` (`Snapshot.coerce_loaded_to_fresh_shape/2`). Normalize to the
      # flat `.state` view (the same T3 chokepoint production consumers
      # use) before the verbatim round-trip assertion.
      assert Ezagent.Kind.normalize_slice_view(loaded.session) == chat_only_slice.session

      # The :publisher slice (added by ExternalMirror PR-EM-0) gets
      # fresh init values via the Q5 merge path in
      # `Ezagent.Kind.Snapshot.load_with_fallback/3`. This is the
      # CORRECT behavior — a pre-PR-EM-0 snapshot doesn't have a
      # :publisher field, and the merge ensures the new Behavior
      # boots with empty ring + cursor=0 rather than crashing on
      # KeyError.
      #
      # Lifecycle migration (SPEC 2026-05-29): `Behavior.Publisher.SessionImpl`
      # now `use Ezagent.Lifecycle`, so the fresh-init `:publisher` slice is
      # the two-container `%{state: %{ring, cursor, retention}, transients:
      # %{}}` shape. `create/1` builds ONLY the persistent fields; the
      # transient `subscribers`/`monitors` maps are NOT in fresh init —
      # `activate/2` fills them empty on every start (so they don't appear
      # in the snapshot-loaded slice at all). Normalize to the flat `.state`
      # view (the T3 chokepoint) and assert the persistent fields.
      assert Ezagent.Kind.normalize_slice_view(loaded.publisher) ==
               %{ring: [], cursor: 0, retention: 100}
    end
  end

  # Phase 7 completion PR-2 (SPEC §2 "PR-2") — the durable
  # `template_working_copy` field on the Chat slice.
  describe "template_working_copy slice (PR-2)" do
    alias Ezagent.ActionSet.Session, as: SessionBehavior

    test "the template_working_copy field round-trips through a Session snapshot/restore" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/twc-roundtrip-#{System.unique_integer([:positive])}"
        )

      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      # A populated, template-SHAPED working copy: agent_slots carry
      # `template://agent` URIs (NOT live `entity://agent`), routing
      # receivers are slot NAMES.
      working_copy = %{
        agent_slots: [
          {"backend", Ezagent.URI.new!("template://system/agent/cc-backend")},
          {"frontend", Ezagent.URI.new!("template://team-alpha/agent/cc-frontend")}
        ],
        routing_rules: [{{:mention, "backend"}, ["backend"]}],
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
        description: "a two-agent team"
      }

      chat_slice = %{
        members: %{},
        monitors: %{},
        last_seen: %{},
        template_working_copy: working_copy
      }

      :ok =
        SnapshotFixtures.save_kind_snapshot(session_uri, Session, %{
          session: chat_slice,
          # P5-0b: explicit :kind_base (backfilled legacy row).
          kind_base: %{state: %{behaviors: Session.behaviors()}, transients: %{}}
        })

      loaded = Snapshot.load_or_init(session_uri, Session, %{uri: session_uri})

      # T4: the loaded flat snapshot is coerced to two-container; the
      # `SessionBehavior.template_working_copy/1` accessor reads the flat `:chat` slice,
      # so pass the normalized `.state` view (same as the production
      # consumers — `McpServer.load_chat_slice`, `Session.read_*`).
      assert SessionBehavior.template_working_copy(
               Ezagent.Kind.normalize_slice_view(loaded.session)
             ) ==
               working_copy,
             "the durable template_working_copy field must survive a Session " <>
               "snapshot/restore — Session is {:snapshot, :on_change}"
    end

    test "a pre-PR-2 Session snapshot (no template_working_copy key) still loads — field defaults" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/twc-pre-pr2-#{System.unique_integer([:positive])}"
        )

      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      member =
        Ezagent.URI.new!("entity://team-alpha/user/pre-#{System.unique_integer([:positive])}")

      # The exact pre-PR-2 `:chat` slice shape — members/monitors/last_seen
      # only, NO `template_working_copy` key.
      pre_pr2_chat = %{members: %{member => %{online: true}}, monitors: %{}, last_seen: %{}}
      refute Map.has_key?(pre_pr2_chat, :template_working_copy)

      :ok =
        SnapshotFixtures.save_kind_snapshot(session_uri, Session, %{
          session: pre_pr2_chat,
          # P5-0b: explicit :kind_base (backfilled legacy row).
          kind_base: %{state: %{behaviors: Session.behaviors()}, transients: %{}}
        })

      # The snapshot loads without crashing. T4: the legacy flat slice is
      # coerced to the two-container `%{state, transients}` shape on load
      # (Chat is now `use Ezagent.Lifecycle`); normalize to the flat
      # `.state` view to inspect the persistent fields. It still has no
      # `template_working_copy` key (the snapshot layer merges at
      # slice-key level, so the loaded slice replaces the fresh one).
      loaded = Snapshot.load_or_init(session_uri, Session, %{uri: session_uri})
      loaded_chat = Ezagent.Kind.normalize_slice_view(loaded.session)
      assert Map.has_key?(loaded_chat, :members)
      assert loaded_chat.members == pre_pr2_chat.members

      # Reading the field via the accessor yields the empty default —
      # no crash, the field gracefully defaults.
      assert SessionBehavior.template_working_copy(loaded_chat) ==
               SessionBehavior.default_template_working_copy()
    end
  end
end
