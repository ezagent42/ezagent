defmodule EzagentDomainSocialware.Integration.ParentCommitRollbackTest do
  @moduledoc """
  P2.5c rev4 HIGH gate — the load-bearing acceptance test.

  When `turn.settle` prepares the settlement and the parent `:turns` slice
  commit then FAILS (issue #342, `{:persistence_failed, _}`), NO committed
  customer delivery may leak: the settlement must NOT be `:committed`, the
  customer outbox must carry no committed delivery, and the customer feed
  must expose neither the page nor the messages.

  Pre-P2.5c this test FAILS: the settlement's `approve` + `commit_settlement`
  ran synchronously INSIDE the handler (before the parent commit), so a
  committed delivery existed for a turn that never durably settled — an
  orphan delivery. P2.5c defers those dispatches until AFTER the parent
  commit succeeds, so a forced commit failure skips them entirely.

  ## Force-fail seam

  Uses the P2.5c TEST-ONLY app-env seam in `Ezagent.Kind.Snapshot.commit/4`
  (`:ezagent_core, :p2_5c_force_commit_failure_uris`) — `nil` in dev/prod, so
  it is a pure no-op off this test path. Setting it for one session URI makes
  that session's parent commit return `{:error, _}` exactly as a genuine
  `save_now` failure would. (Flagged for codex review: the seam is the minimal
  deterministic injection the gate requires; there is no pre-existing
  per-dispatch commit-failure hook.)
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, MessageStore}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.{ExternalFeed, DeliveryOutbox, Settlement}

  @owner Ezagent.URI.entity(:team_alpha, :user, "parent-rollback-owner")

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "rollback-#{System.unique_integer([:positive])}"
    )
  end

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args, caps \\ nil) do
    target = target(session_uri, behavior, action)
    caller = User.admin_uri()
    caps = caps || Ezagent.Socialware.TestCapHelper.lifecycle_caps(session_uri, caller, target)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        caps: caps,
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
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

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session,
        owner_uri: @owner,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, ExternalFeed.topic(session))

    on_exit(fn ->
      Application.delete_env(:ezagent_core, :p2_5c_force_commit_failure_uris)
    end)

    %{session: session, caller: @owner}
  end

  test "a forced parent-commit failure on turn.settle leaks NO committed delivery", ctx do
    page_tree = %{type: "text", props: %{text: "rollback page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{status: :composing, version: version, message_ids: [_message_id]}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "rollback answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    wait_until(fn ->
      {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
      Map.has_key?(surface.versions, version)
    end)

    # No delivery yet (pre-settle).
    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert snapshot.messages == []
    assert snapshot.page == nil

    # Arm the force-fail seam for THIS session, then settle. The parent
    # `:turns` slice commit will fail; the deferred approve/commit_settlement
    # must be SKIPPED.
    settle_target = target(ctx.session, :turn, :settle)

    settle_caps =
      Ezagent.Socialware.TestCapHelper.lifecycle_caps(
        ctx.session,
        User.admin_uri(),
        settle_target
      )

    Application.put_env(
      :ezagent_core,
      :p2_5c_force_commit_failure_uris,
      MapSet.new([URI.to_string(ctx.session)])
    )

    assert {:error, {:persistence_failed, {:p2_5c_forced_commit_failure, _}}} =
             dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id}, settle_caps)

    # The orphan delivery must NOT appear. Give the (incorrectly-running)
    # deferred dispatch a window to leak if the gate were broken.
    refute_receive {:external_delivery, _}, 300

    # (1) Settlement is NOT committed — either no record, or still :pending
    #     (prepare_settlement created the :pending record BEFORE the parent
    #     commit; the deferred commit_settlement never ran).
    case Settlement.get(turn_id) do
      :error -> :ok
      {:ok, record} -> refute record.status == :committed
    end

    # (2) The customer outbox has no committed delivery for this turn.
    outbox =
      EzagentCore.Repo.get_by(DeliveryOutbox, turn_id: turn_id) ||
        EzagentCore.Repo.get_by(DeliveryOutbox, session_uri: URI.to_string(ctx.session))

    case outbox do
      nil -> :ok
      row -> assert is_nil(row.committed_seq)
    end

    # (3) No committed external-visible messages for the session.
    assert MessageStore.committed_external_visible(ctx.session, 50) == []

    # (4) The customer feed exposes neither the page nor the messages.
    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert snapshot.messages == []
    assert snapshot.page == nil
  end
end
