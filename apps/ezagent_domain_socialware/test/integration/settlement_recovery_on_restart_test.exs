defmodule EzagentDomainSocialware.Integration.SettlementRecoveryOnRestartTest do
  @moduledoc """
  P2.5c crash-window recovery (codex rev2 HIGH) — `Turn.activated/2` replays
  settled-but-pending settlements on restart.

  The deferred settlement dispatch (Task 5) is the FAST path; it is an
  in-memory cast. A BEAM crash AFTER `commit_and_notify` durably marks the
  turn `:settled` but BEFORE the deferred approve/commit_settlement run would
  leave a settled turn whose customer delivery never commits — a lost
  delivery. `prepare_settlement` durably creates the `:pending`
  SettlementRecord BEFORE the parent commit, so on every restart
  `activated/2` (post-`:ready`) self-signals `{:ezagent_recover_settlements}`,
  and `handle_signal/2` re-emits approve + commit_settlement as NORMAL
  `:dispatch` for any `:settled` turn whose settlement is still `:pending`.
  Replay is idempotent (re-approve same version; `commit_after_pointer`
  no-ops when committed — P2.5b).

  ## Deterministic crash simulation (no race on the deferred cast)

  We construct the durable post-parent-commit-but-pre-deferred state directly:
    1. open → compose (durable: chat messages + surface version N).
    2. `Settlement.begin` (the `:pending` record `prepare_settlement` leaves)
       + `flip_visibility` — WITHOUT running the deferred approve/commit.
    3. Mark the turn `:settled` in the persisted `:turns` snapshot (what
       `handle_settle` durably leaves) via a direct snapshot write.
    4. Terminate the session via instance_message's SessionSupervisor (the
       unified `Entity.Session`'s supervisor); wait for
       `KindRegistry.lookup == :error`.
    5. Re-spawn → `activated/2` runs → recovery commits the settlement; the
       committed customer delivery appears.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.{ExternalFeed, Settlement}

  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "settle-recovery-owner")

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "settle-recover-#{System.unique_integer([:positive])}"
    )
  end

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    target = target(session_uri, behavior, action)
    caller = owner()

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: Ezagent.Socialware.TestCapHelper.lifecycle_caps(session_uri, caller, target),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 150)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)

    {:ok, pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session,
        owner_uri: owner(),
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    %{session: session, caller: owner(), pid: pid, workspace: workspace}
  end

  test "activated/2 recovers a settled-but-pending settlement on respawn", ctx do
    page_tree = %{type: "text", props: %{text: "recovered page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{status: :composing, version: version, message_ids: [message_id]}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "recovered answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    wait_until(fn ->
      {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
      Map.has_key?(surface.versions, version)
    end)

    # (2) Create the :pending SettlementRecord that prepare_settlement leaves
    # BEFORE the parent commit — WITHOUT running the deferred approve/commit.
    {:ok, _} =
      Settlement.begin(%{
        turn_id: turn_id,
        session_uri: ctx.session,
        workspace_uri: ctx.workspace,
        target_message_ids: [message_id],
        target_surface_version: version,
        expected_prior_approved: nil
      })

    {:ok, _} = Settlement.flip_visibility(turn_id)

    assert {:ok, %{status: :pending}} = Settlement.get(turn_id)

    # No committed delivery yet (the deferred commit was "lost in the crash").
    assert {:ok, snap0} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert snap0.messages == []
    assert snap0.page == nil

    # (3) Mark the turn :settled in the persisted :turns snapshot — what a
    # successful parent commit of handle_settle durably leaves.
    mark_turn_settled_in_snapshot(ctx.session, turn_id)

    # (4) Terminate + wait for deregistration.
    :ok =
      DynamicSupervisor.terminate_child(
        # P5-1b: the unified `Entity.Session` runs under instance_message's
        # SessionSupervisor (its `supervisor/0`), not the legacy socialware one.
        EzagentDomainInstanceMessage.SessionSupervisor,
        ctx.pid
      )

    wait_until(fn -> KindRegistry.lookup(ctx.session) == :error end)

    # (5) Re-spawn → activated/2 runs → recovery commits the settlement.
    {:ok, pid2} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: ctx.session,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    refute ctx.pid == pid2

    # The settled turn re-loaded from the snapshot.
    wait_until(fn ->
      case Ezagent.Kind.get_slice(ctx.session, :turns) do
        {:ok, %{turns: turns}} -> Map.get(turns, turn_id, %{})[:status] == :settled
        _ -> false
      end
    end)

    # Recovery committed the settlement (idempotent re-approve + commit).
    wait_until(fn ->
      match?({:ok, %{status: :committed}}, Settlement.get(turn_id))
    end)

    # The committed customer delivery now appears.
    wait_until(fn ->
      case ExternalFeed.snapshot(ctx.session, ctx.caller) do
        {:ok, snap} ->
          snap.page == page_tree and
            Enum.any?(snap.messages, &message_text?(&1, "recovered answer"))

        _ ->
          false
      end
    end)
  end

  # Read the persisted snapshot, flip the turn to :settled, and write it back.
  # Mirrors what `handle_settle`'s parent `:turns` commit durably leaves.
  defp mark_turn_settled_in_snapshot(session_uri, turn_id) do
    uri_str = URI.to_string(session_uri)
    row = Ezagent.Ecto.KindSnapshot.get(uri_str)
    {:ok, slice_state} = Ezagent.Ecto.KindSnapshot.decode_state(row)

    turns_slice = Map.fetch!(slice_state, :turns)
    # Two-container Lifecycle slice: %{state: %{turns: ..., turn_seq: ...}, ...}.
    inner = Map.fetch!(turns_slice, :state)
    turns = Map.fetch!(inner, :turns)
    turn = Map.fetch!(turns, turn_id)
    updated_turn = %{turn | status: :settled}
    new_inner = %{inner | turns: Map.put(turns, turn_id, updated_turn)}
    new_turns_slice = %{turns_slice | state: new_inner}
    new_slice_state = Map.put(slice_state, :turns, new_turns_slice)

    :ok =
      Ezagent.Test.SnapshotFixtures.save_kind_snapshot(
        uri_str,
        Session,
        new_slice_state
      )
  end

  test "recovery emits NORMAL :dispatch effects, not :dispatch_after_commit", ctx do
    # A settled turn with a pending settlement; handle_signal must re-emit the
    # approve + commit_settlement as `{:dispatch, _}` (run inline by the signal
    # path), NOT `{:dispatch_after_commit, _}` (there is no parent-commit gate
    # to consume deferred effects in the recovery/signal path).
    turn_id = "#{URI.to_string(ctx.session)}#turn-1"

    {:ok, _} =
      Settlement.begin(%{
        turn_id: turn_id,
        session_uri: ctx.session,
        workspace_uri: ctx.workspace,
        target_message_ids: ["msg-x"],
        target_surface_version: 1,
        expected_prior_approved: nil
      })

    settled_turn = %{
      status: :settled,
      result: %{version: 1, message_ids: ["msg-x"]}
    }

    signal_ctx = %{
      self_uri: ctx.session,
      read: fn
        :turns, _default -> %{turn_id => settled_turn}
        _key, default -> default
      end
    }

    assert {:ok, effects} =
             Ezagent.ActionSet.Turn.handle_signal({:ezagent_recover_settlements}, signal_ctx)

    assert effects != []
    assert Enum.all?(effects, &match?({:dispatch, _}, &1))
    refute Enum.any?(effects, &match?({:dispatch_after_commit, _}, &1))
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end
end
