defmodule EzagentDomainChat.Integration.SessionSurvivesRestartTest do
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
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Kind.Snapshot

  # `chat.join` requires the member's Kind alive in KindRegistry; spawn
  # a real User Kind to act as the runtime-added member, mirroring the
  # production "add an agent to a session" flow.
  defp spawn_member do
    member_uri =
      URI.parse("entity://user/default/restart-member-#{System.unique_integer([:positive])}")

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
    {:ok, pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
    # Mirror the production `session` spawn fn: bind the workspace cache.
    :ok =
      Ezagent.WorkspaceRegistry.bind(
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    pid
  end

  defp join(session_uri, member_uri) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: User.admin_uri(),
        caps: User.admin_caps(),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp list_members(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    wrapper = :sys.get_state(pid)
    wrapper.state |> Map.get(:chat, %{}) |> Map.get(:members, %{})
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
        URI.parse("session://default/default/restart-#{System.unique_integer([:positive])}")

      uri_str = URI.to_string(session_uri)

      # Clean slate — no stale snapshot from a prior run.
      :ok = KindSnapshot.delete(uri_str)

      member_uri = spawn_member()

      # 1. Spawn the Session Kind.
      pid1 = spawn_session(session_uri)

      # 2. Add the member at runtime via the production chat.join path.
      assert {:ok, %{members: members}} = join(session_uri, member_uri)
      assert member_uri in members

      # 3. The :on_change snapshot must have been written to kind_snapshots.
      wait_until(fn -> not is_nil(KindSnapshot.get(uri_str)) end)
      assert %KindSnapshot{kind_type: "session"} = KindSnapshot.get(uri_str)

      # 4. Simulate a phx restart: stop the Session Kind process.
      :ok =
        DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, pid1)

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
        URI.parse("session://default/default/fresh-#{System.unique_integer([:positive])}")

      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      _pid = spawn_session(session_uri)

      assert list_members(session_uri) == %{}
    end
  end

  describe "WorkspaceRegistry rebind on rehydrate (invariant 4)" do
    test "respawning a session re-establishes its workspace binding" do
      session_uri =
        URI.parse("session://default/default/ws-rebind-#{System.unique_integer([:positive])}")

      uri_str = URI.to_string(session_uri)
      :ok = KindSnapshot.delete(uri_str)

      member_uri = spawn_member()

      # Spawn via the production `session` SpawnRegistry fn — this is the
      # path that runs `bind_session_workspace/1`.
      {:ok, pid1} = Ezagent.SpawnRegistry.spawn(session_uri)

      assert {:ok, %URI{scheme: "workspace", host: "default"}} =
               Ezagent.WorkspaceRegistry.lookup(session_uri)

      {:ok, _} = join(session_uri, member_uri)
      wait_until(fn -> not is_nil(KindSnapshot.get(uri_str)) end)

      # Drop the Kind AND the ETS binding — simulating a phx restart
      # where ETS (in-memory) is wiped but the snapshot row survives.
      :ok = DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, pid1)
      wait_until(fn -> KindRegistry.lookup(session_uri) == :error end)
      :ok = Ezagent.WorkspaceRegistry.unbind(session_uri)
      assert :error = Ezagent.WorkspaceRegistry.lookup(session_uri)

      # Lazy demand-spawn via SpawnRegistry (the rehydrate path) must
      # rebind the workspace from the 3-segment URI.
      {:ok, _pid2} = Ezagent.SpawnRegistry.spawn(session_uri)

      assert {:ok, %URI{scheme: "workspace", host: "default"}} =
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
        URI.parse("session://default/default/load-init-#{System.unique_integer([:positive])}")

      member = URI.parse("entity://user/default/m-#{System.unique_integer([:positive])}")

      # Old-shape snapshot (chat slice only — pre-PR-EM-0 Session had
      # only [Chat] in behaviors/0). Saved verbatim to simulate a
      # snapshot taken before PR-EM-0 landed.
      chat_only_slice = %{
        chat: %{members: %{member => %{online: true}}, monitors: %{}, last_seen: %{}}
      }

      :ok = Snapshot.save_now(session_uri, Session, chat_only_slice)

      loaded = Snapshot.load_or_init(session_uri, Session, %{uri: session_uri})

      # The chat slice survives the round-trip verbatim.
      assert loaded.chat == chat_only_slice.chat

      # The :publisher slice (added by ExternalMirror PR-EM-0) gets
      # fresh init values via the Q5 merge path in
      # `Ezagent.Kind.Snapshot.load_with_fallback/3`. This is the
      # CORRECT behavior — a pre-PR-EM-0 snapshot doesn't have a
      # :publisher field, and the merge ensures the new Behavior
      # boots with empty ring + cursor=0 rather than crashing on
      # KeyError. See SessionImpl.init_slice/1 for the default shape.
      assert %{ring: [], cursor: 0, retention: 100, subscribers: %{}, monitors: %{}} =
               loaded.publisher
    end
  end

  # Phase 7 completion PR-2 (SPEC §2 "PR-2") — the durable
  # `template_working_copy` field on the Chat slice.
  describe "template_working_copy slice (PR-2)" do
    alias Ezagent.Behavior.Chat

    test "the template_working_copy field round-trips through a Session snapshot/restore" do
      session_uri =
        URI.parse("session://default/default/twc-roundtrip-#{System.unique_integer([:positive])}")

      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      # A populated, template-SHAPED working copy: agent_slots carry
      # `template://agent` URIs (NOT live `entity://agent`), routing
      # receivers are slot NAMES.
      working_copy = %{
        agent_slots: [
          {"backend", URI.parse("template://agent/default/cc-backend")},
          {"frontend", URI.parse("template://agent/default/cc-frontend")}
        ],
        routing_rules: [{{:mention, "backend"}, ["backend"]}],
        orchestrator_template_uri: URI.parse("template://agent/default/cc-orchestrator"),
        default_workspace_uri: URI.parse("workspace://default"),
        description: "a two-agent team"
      }

      chat_slice = %{
        members: %{},
        monitors: %{},
        last_seen: %{},
        template_working_copy: working_copy
      }

      :ok = Snapshot.save_now(session_uri, Session, %{chat: chat_slice})

      loaded = Snapshot.load_or_init(session_uri, Session, %{uri: session_uri})

      assert Chat.template_working_copy(loaded.chat) == working_copy,
             "the durable template_working_copy field must survive a Session " <>
               "snapshot/restore — Session is {:snapshot, :on_change}"
    end

    test "a pre-PR-2 Session snapshot (no template_working_copy key) still loads — field defaults" do
      session_uri =
        URI.parse("session://default/default/twc-pre-pr2-#{System.unique_integer([:positive])}")

      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      member = URI.parse("entity://user/default/pre-#{System.unique_integer([:positive])}")

      # The exact pre-PR-2 `:chat` slice shape — members/monitors/last_seen
      # only, NO `template_working_copy` key.
      pre_pr2_chat = %{members: %{member => %{online: true}}, monitors: %{}, last_seen: %{}}
      refute Map.has_key?(pre_pr2_chat, :template_working_copy)

      :ok = Snapshot.save_now(session_uri, Session, %{chat: pre_pr2_chat})

      # The snapshot loads without crashing; the loaded `:chat` slice
      # has no `template_working_copy` key (the snapshot layer merges
      # at slice-key level, so the loaded slice replaces the fresh one).
      loaded = Snapshot.load_or_init(session_uri, Session, %{uri: session_uri})
      assert Map.has_key?(loaded.chat, :members)
      assert loaded.chat.members == pre_pr2_chat.members

      # Reading the field via the accessor yields the empty default —
      # no crash, the field gracefully defaults.
      assert Chat.template_working_copy(loaded.chat) == Chat.default_template_working_copy()
    end
  end
end
