defmodule EzagentDomainInstanceMessage.Integration.SessionUnionKindDenialTest do
  @moduledoc """
  P5-1b (socialware substrate collapse) — the LOAD-BEARING per-instance denial
  gate on the UNIFIED `Ezagent.Entity.Session` Kind.

  After the collapse, `Entity.Session.behaviors/0` is the UNION
  `[Session, Publisher.SessionImpl, ExternalMirror, Turn, Surface]`. Templates
  pick the per-instance ACTIVE subset via the `:kind_base` set threaded at spawn
  (`chat_behaviors/0` vs `socialware_behaviors/0`). This suite proves the
  superset Kind does NOT widen authority:

    * a CHAT-subset instance DENIES `turn.*` / `surface.*` (out-of-set →
      `effective_set/2` excludes them → `instance_set_gate`/E9 rejects), while
      still admitting `session.*`.
    * a SOCIALWARE-subset instance ALLOWS `turn.*` / `surface.*` and `session.*`.

  Plus the P5-2 cold-restart rehydration property: an EXISTING session snapshot
  (kind_type "session") rehydrates on the unified Kind with the per-instance set
  taken from its PERSISTED `:kind_base`, NOT from the spawn args of the
  demand-spawn route — so a backfilled socialware row is not downgraded to chat.

  Per `feedback_completion_requires_invariant_test`: this FAILS exactly when the
  superset Kind widens authority (Turn/Surface become invokable on a chat
  instance) or when rehydration ignores the persisted `:kind_base`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.{Surface, Turn}
  alias Ezagent.ActionSet.Publisher.SessionImpl
  alias Ezagent.ActionSet.{ExternalMirror, Session, KindBase, SelfLicense}
  alias Ezagent.Entity.Session, as: SessionKind
  alias Ezagent.Entity.User
  alias Ezagent.Invocation
  alias Ezagent.Kind.BehaviorSet
  alias Ezagent.Kind.Snapshot
  alias Ezagent.Test.SnapshotFixtures

  defp session_uri(prefix) do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "#{prefix}-#{System.unique_integer([:positive])}"
    )
  end

  defp spawn_session(session_uri, behaviors) do
    :ok = Ezagent.Ecto.KindSnapshot.delete(URI.to_string(session_uri))

    {:ok, pid} = Ezagent.Kind.spawn(SessionKind, %{uri: session_uri, behaviors: behaviors})

    :ok =
      Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

    pid
  end

  defp dispatch(session_uri, behavior, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # ── the union declaration + the two subsets ────────────────────────────────

  test "Entity.Session.behaviors/0 is the chat+socialware UNION" do
    assert SessionKind.behaviors() == [
             SelfLicense,
             Session,
             SessionImpl,
             ExternalMirror,
             Turn,
             Surface,
             Ezagent.ActionSet.SupervisorApproval
           ]
  end

  test "chat_behaviors/0 excludes Turn/Surface; socialware_behaviors/0 excludes ExternalMirror" do
    assert SessionKind.chat_behaviors() == [SelfLicense, Session, SessionImpl, ExternalMirror]

    assert SessionKind.socialware_behaviors() == [
             SelfLicense,
             Session,
             Turn,
             Surface,
             Ezagent.ActionSet.SupervisorApproval,
             SessionImpl
           ]

    refute Turn in SessionKind.chat_behaviors()
    refute Surface in SessionKind.chat_behaviors()
    refute ExternalMirror in SessionKind.socialware_behaviors()

    # Both subsets are intersections of the declared union (nothing extra).
    declared = MapSet.new(SessionKind.behaviors())
    assert Enum.all?(SessionKind.chat_behaviors(), &MapSet.member?(declared, &1))
    assert Enum.all?(SessionKind.socialware_behaviors(), &MapSet.member?(declared, &1))
  end

  # ── effective_set: the per-instance active set on the union Kind ────────────

  test "effective_set on a CHAT :kind_base excludes Turn/Surface" do
    slice = %{kind_base: %{state: %{behaviors: SessionKind.chat_behaviors()}, transients: %{}}}
    eff = BehaviorSet.effective_set(SessionKind, slice)

    assert Session in eff
    assert ExternalMirror in eff
    refute Turn in eff
    refute Surface in eff
  end

  test "effective_set on a SOCIALWARE :kind_base includes Turn/Surface and excludes ExternalMirror" do
    slice = %{
      kind_base: %{state: %{behaviors: SessionKind.socialware_behaviors()}, transients: %{}}
    }

    eff = BehaviorSet.effective_set(SessionKind, slice)

    assert Session in eff
    assert Turn in eff
    assert Surface in eff
    refute ExternalMirror in eff
  end

  # ── THE LOAD-BEARING GATE: dispatch denial on a CHAT instance ───────────────

  test "CHAT instance DENIES turn.* and surface.* (instance_set_gate / E9)" do
    uri = session_uri("union-chat")
    _pid = spawn_session(uri, SessionKind.chat_behaviors())

    turn_result = dispatch(uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})
    assert {:error, :behavior_not_in_instance_set} = turn_result

    surface_result =
      dispatch(uri, :surface, :put_version, %{turn_id: "t1", page: %{type: "container"}})

    assert {:error, :behavior_not_in_instance_set} = surface_result
  end

  test "CHAT instance still ADMITS session.* (the gate does not over-deny in-set behaviors)" do
    uri = session_uri("union-chat-allow")
    _pid = spawn_session(uri, SessionKind.chat_behaviors())

    # The gate must NOT short-circuit an in-set behavior. The exact success/error
    # shape of session.join is owned by Session+authz; we assert ONLY that the
    # per-instance gate did not fire.
    result = dispatch(uri, :session, :join, %{member: User.admin_uri(), role_name: "member"})
    refute match?({:error, :behavior_not_in_instance_set}, result)
  end

  # ── dispatch ALLOW on a SOCIALWARE instance ─────────────────────────────────

  test "SOCIALWARE instance ALLOWS turn.* (reaches the handler, not the gate)" do
    uri = session_uri("union-soc")
    _pid = spawn_session(uri, SessionKind.socialware_behaviors())

    result = dispatch(uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    # In-set → NOT denied by the per-instance gate. A successful open returns a
    # turn_id; either way it must not be the gate denial.
    refute match?({:error, :behavior_not_in_instance_set}, result)
    assert match?({:ok, %{turn_id: _}}, result)
  end

  test "SOCIALWARE instance ALLOWS surface.* (reaches the handler, not the gate)" do
    uri = session_uri("union-soc-surface")
    _pid = spawn_session(uri, SessionKind.socialware_behaviors())

    # surface.put_version requires a live turn; open one first.
    assert {:ok, %{turn_id: turn_id}} =
             dispatch(uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    result =
      dispatch(uri, :surface, :put_version, %{
        turn_id: turn_id,
        page: %{type: "container", children: []}
      })

    refute match?({:error, :behavior_not_in_instance_set}, result)
  end

  test "SOCIALWARE instance ALLOWS session.* too" do
    uri = session_uri("union-soc-session")
    _pid = spawn_session(uri, SessionKind.socialware_behaviors())

    result = dispatch(uri, :session, :join, %{member: User.admin_uri(), role_name: "member"})
    refute match?({:error, :behavior_not_in_instance_set}, result)
  end

  # ── P5-2 cold-restart rehydration: persisted :kind_base wins ────────────────

  test "RELOAD derives the per-instance set from the PERSISTED socialware :kind_base, NOT spawn args" do
    uri = session_uri("union-rehydrate-soc")
    :ok = Ezagent.Ecto.KindSnapshot.delete(URI.to_string(uri))

    # First spawn (cold) with the socialware subset → persist.
    fresh =
      Snapshot.load_or_init(uri, SessionKind, %{behaviors: SessionKind.socialware_behaviors()})

    :ok = SnapshotFixtures.save_kind_snapshot(uri, SessionKind, fresh)

    # Cold-reload via the SAME args the demand-spawn "session" SpawnRegistry route
    # passes (chat_behaviors) — the persisted socialware :kind_base MUST win, so
    # the rehydrated session is NOT downgraded to chat.
    reloaded = Snapshot.load_or_init(uri, SessionKind, %{behaviors: SessionKind.chat_behaviors()})

    assert KindBase.behaviors_in_slice(reloaded[:kind_base]) == SessionKind.socialware_behaviors()

    eff = BehaviorSet.effective_set(SessionKind, reloaded)
    assert Turn in eff
    assert Surface in eff
    refute ExternalMirror in eff
  end

  test "RELOAD of a CHAT :kind_base snapshot stays chat (Turn/Surface excluded)" do
    uri = session_uri("union-rehydrate-chat")
    :ok = Ezagent.Ecto.KindSnapshot.delete(URI.to_string(uri))

    fresh = Snapshot.load_or_init(uri, SessionKind, %{behaviors: SessionKind.chat_behaviors()})
    :ok = SnapshotFixtures.save_kind_snapshot(uri, SessionKind, fresh)

    reloaded =
      Snapshot.load_or_init(uri, SessionKind, %{behaviors: SessionKind.socialware_behaviors()})

    assert KindBase.behaviors_in_slice(reloaded[:kind_base]) == SessionKind.chat_behaviors()

    eff = BehaviorSet.effective_set(SessionKind, reloaded)
    assert Session in eff
    assert ExternalMirror in eff
    refute Turn in eff
    refute Surface in eff
  end
end
