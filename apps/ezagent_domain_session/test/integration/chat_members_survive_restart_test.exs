defmodule EzagentDomainInstanceMessage.Integration.ChatMembersSurviveRestartTest do
  @moduledoc """
  THE GATE for the Chat Lifecycle migration (SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6 —
  "session-members-survive-restart").

  This is the architectural-goal invariant test for `Ezagent.ActionSet.Session`
  after its conversion to `use Ezagent.Lifecycle` (Phase B, representative
  example C — the RICH case). It pins the two-container `state` / `transients`
  split on a real cold restart and proves the **latent stale-monitor-ref
  bug (§2.3C) is fixed**:

  - `members` lives in `state` → it MUST survive a cold restart
    (rehydrated from the snapshot).
  - `monitors` (the `ref → URI` map from `Process.monitor`) lives in
    `transients` → it MUST be REBUILT LIVE by `activate/2` on every start,
    NOT restored. Before the migration `monitors` was persisted in the
    SAME `:chat` slice and rehydrated as DEAD refs, so
    `handle_signal({:DOWN, ...})` could never match them — offline
    detection silently degraded. This test asserts the rebuilt monitors
    are FRESH (different refs from the pre-restart incarnation), all live
    members are monitored, and NO dead ref survived.

  Uses `Ezagent.LifecycleCase.assert_transients_rebuilt/2` — the reusable
  cold-restart gate. Per `feedback_completion_requires_invariant_test`
  this FAILS exactly when the cold-restart bug class reappears (a
  transient persisted, or an `activate/2` rebuild deleted).

  ## Why a Chat-only test Kind

  The production `Ezagent.Entity.Session` Kind composes many Behaviors
  (orchestrator admin / template / publisher / …) whose boot drags in
  flavor resolution + orchestrator spawn — orthogonal to the chat
  state/transient split this gate targets. A dedicated Kind composing
  ONLY `Ezagent.ActionSet.Session` isolates the migration's invariant exactly,
  mirroring the SPEC Phase A fixture pattern
  (`Ezagent.TestSupport.LifecycleFixtureKind`).
  """

  use Ezagent.LifecycleCase

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Entity.User

  # ------------------------------------------------------------------
  # Chat-only test Kind. `{:snapshot, :on_change}` so the persistent
  # `state` survives a cold restart (and the transient `monitors` is
  # proven REBUILT, not restored). No `supervisor/0` → spawns under the
  # core's `Ezagent.KindSupervisor` as a `:permanent` child, so the
  # `Process.exit(pid, :kill)` in `assert_transients_rebuilt/2` triggers
  # an OTP auto-restart at the same URI (the production-faithful cold-load
  # path).
  # ------------------------------------------------------------------
  defmodule ChatOnlyKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl Ezagent.Kind
    def type_name, do: :session

    @impl Ezagent.Kind
    def behaviors, do: [Ezagent.ActionSet.Session]

    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}
  end

  setup_all do
    Code.ensure_loaded!(ChatOnlyKind)

    # Register the Session behavior's actions for the test Kind so dispatch can
    # resolve `session.join` (production Kinds register at app boot). Single
    # canonical chokepoint; idempotent upsert.
    for action <- [:join, :leave, :send] do
      if Ezagent.BehaviorRegistry.lookup(ChatOnlyKind, action) == :error do
        :ok = Ezagent.CapabilityRegistry.register(ChatOnlyKind, action, SessionBehavior)
      end
    end

    :ok
  end

  # Spawn a real User Kind to act as the runtime-added member — `chat.join`
  # requires the member's Kind alive in KindRegistry so `Process.monitor`
  # has a live pid to watch.
  defp spawn_member do
    member_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/restart-mon-#{System.unique_integer([:positive])}"
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

    {member_uri, member_pid}
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

  describe "session-members-survive-restart — THE GATE (§2.3C)" do
    test "members survive cold-load in state; monitors rebuilt LIVE in transients (no stale ref)" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/chat-restart-#{System.unique_integer([:positive])}"
        )

      # Clean slate — no stale snapshot.
      :ok = Ezagent.Ecto.KindSnapshot.delete(URI.to_string(session_uri))

      {member_uri, member_pid} = spawn_member()

      result =
        assert_transients_rebuilt(
          %{
            kind: ChatOnlyKind,
            uri: session_uri,
            slice_key: :session,
            spawn_args: %{}
          },
          fn live_uri ->
            # Workspace-bind so the Chat handlers' WorkspaceRegistry
            # lookups resolve (join's first-owner-cap grant + send's
            # workspace-scoped routing); join itself does not write to
            # MessageStore, so this is sufficient to drive a monitor in.
            :ok =
              Ezagent.WorkspaceRegistry.bind(
                live_uri,
                Ezagent.Capability.workspace_of(live_uri)
              )

            # Drive the production grant-only join path. The holder's
            # convergence hook performs add_self and installs the monitor.
            assert {:ok, %{status: :granted, member: ^member_uri}} =
                     join(live_uri, member_uri)

            wait_until(fn ->
              case Ezagent.Kind.read(live_uri, :session, spawn: :never) do
                {:ok, slice} ->
                  state = Ezagent.Kind.normalize_slice_view(slice)
                  Map.has_key?(Map.get(state, :members, %{}), member_uri)

                _ ->
                  false
              end
            end)
          end
        )

      # --- 1. STATE survived the cold restart (members rehydrated) ---
      members_after = result.after.state.members

      assert Map.has_key?(members_after, member_uri),
             "member was LOST across cold restart — `members` must live in `state`"

      assert members_after[member_uri].online == true

      # --- 2. TRANSIENTS rebuilt LIVE (the stale-monitor bug is fixed) ---
      monitors_before = result.before.transients.monitors
      monitors_after = result.after.transients.monitors

      # The rebuilt monitor map maps fresh refs → the SAME member URI.
      assert map_size(monitors_after) == 1,
             "activate/2 must rebuild exactly one monitor for the single live member"

      [{ref_after, uri_after}] = Map.to_list(monitors_after)
      assert is_reference(ref_after)
      assert URI.to_string(uri_after) == URI.to_string(member_uri)

      # --- 3. NO STALE REF survived — the rebuilt ref is FRESH ---
      [{ref_before, _}] = Map.to_list(monitors_before)

      refute ref_after == ref_before,
             "monitor ref carried a STALE reference across the restart — it was " <>
               "persisted + rehydrated instead of rebuilt by activate/2 (the §2.3C bug)"

      # --- 4. The rebuilt monitor is a REAL, LIVE monitor on the member ---
      # `activate/2` calls `Process.monitor(member_pid)`; the watched pid is
      # the member Kind's live pid, so the host process appears in the
      # member's :monitored_by set.
      {:ok, host_pid_after} = KindRegistry.lookup(session_uri)
      {:monitored_by, monitored_by} = Process.info(member_pid, :monitored_by)

      assert host_pid_after in monitored_by,
             "the rebuilt monitor is not a live Process.monitor on the member — " <>
               "activate/2 did not actually re-monitor the persisted member set"

      # --- 5. monitors is NEVER persisted (it is absent from the snapshot's
      #        :state, only present in :transients) ---
      refute Map.has_key?(result.after.state, :monitors),
             ":monitors leaked into persistent state — it MUST be a transient only"

      on_exit(fn ->
        Ezagent.WorkspaceRegistry.unbind(session_uri)
        Ezagent.Ecto.KindSnapshot.delete(URI.to_string(session_uri))
      end)
    end
  end
end
