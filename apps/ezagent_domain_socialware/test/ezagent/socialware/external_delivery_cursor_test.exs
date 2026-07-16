defmodule Ezagent.Socialware.ExternalDeliveryCursorTest do
  @moduledoc """
  P2.5b — the external-delivery outbox is a durable, cursor-addressable source.
  committed_seq is assigned at the commit boundary in commit order (per session),
  so replay never skips an out-of-order-committed row; pending rows are invisible;
  the page follows commit order (rollback-correct, tie-correct).
  """
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Invocation
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.{DeliveryOutbox, ExternalFeed, SettlementRecord}
  alias EzagentCore.Repo

  @owner Ezagent.URI.entity(:team_alpha, :user, "delivery-cursor-owner")

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "p2-5b-#{System.unique_integer([:positive])}")
  end

  defp agent_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp target(s, b, a), do: Ezagent.URI.new!("#{URI.to_string(s)}?action=#{b}.#{a}")

  defp dispatch(s, b, a, args) do
    Invocation.dispatch(%Invocation{origin: :trusted_internal,
      target: target(s, b, a),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts),
    do:
      if(fun.(),
        do: :ok,
        else:
          (
            Process.sleep(20)
            wait_until(fun, attempts - 1)
          )
      )

  defp spawn_session do
    uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(uri))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: uri,
        owner_uri: @owner,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  # The external read is authorized by LIVE membership (the session owner), not
  # an identity-less token. The delivery-cursor projection is auth-agnostic.
  defp test_caller(_session_uri), do: @owner

  # full turn -> committed delivery; returns turn_id.
  defp run_turn(uri, page_tree) do
    {:ok, %{turn_id: turn_id}} =
      dispatch(uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    {:ok, _} =
      dispatch(uri, :turn, :dispatch, %{
        turn_id: turn_id,
        subtasks: [%{id: :page, mention: agent_uri("page"), prompt: "render"}]
      })

    {:ok, _} =
      dispatch(uri, :turn, :deliver, %{
        turn_id: turn_id,
        subtask_id: :page,
        card_ref: %{kind: :page, tree: page_tree}
      })

    {:ok, %{version: _v}} = dispatch(uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})
    {:ok, %{status: :settled}} = dispatch(uri, :turn, :settle, %{turn_id: turn_id})

    wait_until(fn ->
      case Repo.get_by(DeliveryOutbox, turn_id: turn_id) do
        %{committed_seq: seq} when is_integer(seq) -> true
        _ -> false
      end
    end)

    turn_id
  end

  describe "committed_seq assignment" do
    test "the first committed delivery gets committed_seq 1 + records surface_version" do
      uri = spawn_session()
      turn_id = run_turn(uri, %{type: "text", props: %{text: "p1"}})

      row = Repo.get_by(DeliveryOutbox, turn_id: turn_id)
      assert row.committed_seq == 1
      assert row.surface_version == 1
    end

    test "successive committed deliveries get increasing per-session committed_seq" do
      uri = spawn_session()
      t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      t2 = run_turn(uri, %{type: "text", props: %{text: "p2"}})

      assert Repo.get_by(DeliveryOutbox, turn_id: t1).committed_seq == 1
      assert Repo.get_by(DeliveryOutbox, turn_id: t2).committed_seq == 2
    end
  end

  describe "committed_deliveries_since/2" do
    test "returns committed deliveries with committed_seq > cursor, ascending" do
      uri = spawn_session()
      t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      t2 = run_turn(uri, %{type: "text", props: %{text: "p2"}})

      all = ExternalFeed.committed_deliveries_since(uri, 0)
      assert Enum.map(all, & &1.turn_id) == [t1, t2]
      assert Enum.map(all, & &1.cursor) == [1, 2]
      assert List.last(all).surface_version == 2

      assert Enum.map(ExternalFeed.committed_deliveries_since(uri, 1), & &1.turn_id) == [t2]
      assert ExternalFeed.committed_deliveries_since(uri, 2) == []
    end

    test "latest_cursor/1 is the max committed_seq (0 when none)" do
      uri = spawn_session()
      assert ExternalFeed.latest_cursor(uri) == 0
      _ = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      assert ExternalFeed.latest_cursor(uri) == 1
    end
  end

  describe "pending rows are invisible + never skipped (codex rev2 hazard)" do
    test "a pending settlement's outbox row has nil committed_seq and is not replayed; on commit it gets the NEXT seq" do
      uri = spawn_session()
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)

      t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      assert Repo.get_by(DeliveryOutbox, turn_id: t1).committed_seq == 1

      pending_turn = "#{URI.to_string(uri)}#turn-pending"

      {:ok, _} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: pending_turn,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: 2
        })

      {:ok, _} =
        Repo.insert(%DeliveryOutbox{
          turn_id: pending_turn,
          session_uri: URI.to_string(uri),
          workspace_uri: URI.to_string(workspace_uri),
          message_ids: [],
          surface_version: 2,
          committed_seq: nil,
          emitted_at: DateTime.utc_now()
        })

      assert Repo.get_by(DeliveryOutbox, turn_id: pending_turn).committed_seq == nil
      assert Enum.map(ExternalFeed.committed_deliveries_since(uri, 0), & &1.turn_id) == [t1]

      t3 = run_turn(uri, %{type: "text", props: %{text: "p3"}})
      assert Repo.get_by(DeliveryOutbox, turn_id: t3).committed_seq == 2

      # mark_committed_for_test now does the full commit (status + seq + surface_version).
      {:ok, _} = Ezagent.Socialware.Settlement.mark_committed_for_test(pending_turn)

      assert Repo.get_by(DeliveryOutbox, turn_id: pending_turn).committed_seq == 3

      assert Enum.map(ExternalFeed.committed_deliveries_since(uri, 2), & &1.turn_id) == [
               pending_turn
             ]
    end
  end

  describe "upgrade: pending outbox row with nil surface_version (codex rev1 HIGH-1)" do
    test "committing it assigns BOTH committed_seq and surface_version from the settlement" do
      uri = spawn_session()
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)
      turn_id = "#{URI.to_string(uri)}#turn-legacy"

      {:ok, _} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: turn_id,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: 7
        })

      {:ok, _} =
        Repo.insert(%DeliveryOutbox{
          turn_id: turn_id,
          session_uri: URI.to_string(uri),
          workspace_uri: URI.to_string(workspace_uri),
          message_ids: [],
          surface_version: nil,
          committed_seq: nil,
          emitted_at: DateTime.utc_now()
        })

      {:ok, _} = Ezagent.Socialware.Settlement.mark_committed_for_test(turn_id)

      row = Repo.get_by(DeliveryOutbox, turn_id: turn_id)
      assert row.committed_seq == 1
      assert row.surface_version == 7

      [d] = ExternalFeed.committed_deliveries_since(uri, 0)
      assert d.surface_version == 7
    end
  end

  describe "re-commit is a full no-op (codex rev1 HIGH-2): page does not roll back" do
    test "re-committing an older turn after a newer one preserves committed_at + latest page" do
      uri = spawn_session()
      caller = test_caller(uri)
      t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      t2 = run_turn(uri, %{type: "text", props: %{text: "p2"}})

      {:ok, s1_before} = Ezagent.Socialware.Settlement.get(t1)
      assert s1_before.status == :committed

      {:ok, %{status: :committed}} = Ezagent.Socialware.Settlement.commit_after_pointer(t1, nil)

      {:ok, s1_after} = Ezagent.Socialware.Settlement.get(t1)
      assert s1_after.committed_at == s1_before.committed_at
      assert Repo.get_by(DeliveryOutbox, turn_id: t1).committed_seq == 1

      assert Enum.map(ExternalFeed.committed_deliveries_since(uri, 0), & &1.turn_id) == [t1, t2]
      {:ok, snapshot} = ExternalFeed.snapshot(uri, caller)
      assert snapshot.page == %{type: "text", props: %{text: "p2"}}
    end
  end

  describe "committed_at tie: page follows committed_seq, not lexicographic turn_id (codex rev2 HIGH)" do
    test "two latest deliveries sharing committed_at -> page is the max-committed_seq version" do
      uri = spawn_session()
      caller = test_caller(uri)

      turn_ids = for n <- 1..10, do: run_turn(uri, %{type: "text", props: %{text: "p#{n}"}})
      t9 = Enum.at(turn_ids, 8)
      t10 = Enum.at(turn_ids, 9)

      {:ok, s10} = Ezagent.Socialware.Settlement.get(t10)

      from(s in SettlementRecord, where: s.turn_id in ^[t9, t10])
      |> Repo.update_all(set: [committed_at: s10.committed_at])

      assert Repo.get_by(DeliveryOutbox, turn_id: t9).committed_seq == 9
      assert Repo.get_by(DeliveryOutbox, turn_id: t10).committed_seq == 10

      {:ok, snapshot} = ExternalFeed.snapshot(uri, caller)
      assert snapshot.page == %{type: "text", props: %{text: "p10"}}

      assert List.last(ExternalFeed.committed_deliveries_since(uri, 0)).turn_id == t10
    end
  end

  describe "rollback to an older retained version (codex rev4 HIGH): page follows commit order, not max(version)" do
    test "commit v2, then commit a rollback to v1 -> page is v1 (commit-order, not the max version)" do
      uri = spawn_session()
      caller = test_caller(uri)
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)

      _t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      _t2 = run_turn(uri, %{type: "text", props: %{text: "p2"}})

      {:ok, snap2} = ExternalFeed.snapshot(uri, caller)
      assert snap2.page == %{type: "text", props: %{text: "p2"}}

      rollback_turn = "#{URI.to_string(uri)}#turn-rollback"

      {:ok, _} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: rollback_turn,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: 1
        })

      {:ok, _} =
        Repo.insert(%DeliveryOutbox{
          turn_id: rollback_turn,
          session_uri: URI.to_string(uri),
          workspace_uri: URI.to_string(workspace_uri),
          message_ids: [],
          surface_version: 1,
          committed_seq: nil,
          emitted_at: DateTime.utc_now()
        })

      {:ok, _} = Ezagent.Socialware.Settlement.mark_committed_for_test(rollback_turn)

      assert Repo.get_by(DeliveryOutbox, turn_id: rollback_turn).committed_seq == 3
      {:ok, snap1} = ExternalFeed.snapshot(uri, caller)
      assert snap1.page == %{type: "text", props: %{text: "p1"}}
    end
  end

  describe "backfill_committed_seq! (codex rev3 HIGH): legacy committed rows get commit-order seq" do
    test "NULL-seq committed rows are numbered; tied committed_at -> higher version gets higher seq (not lexicographic)" do
      uri = spawn_session()
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)
      now = DateTime.utc_now()

      legacy = [
        {"#{URI.to_string(uri)}#turn-9", 1},
        {"#{URI.to_string(uri)}#turn-10", 2}
      ]

      for {turn_id, ver} <- legacy do
        {:ok, _} =
          Ezagent.Socialware.Settlement.begin(%{
            turn_id: turn_id,
            session_uri: uri,
            workspace_uri: workspace_uri,
            target_message_ids: [],
            target_surface_version: ver
          })

        from(s in SettlementRecord, where: s.turn_id == ^turn_id)
        |> Repo.update_all(set: [status: :committed, committed_at: now])

        {:ok, _} =
          Repo.insert(%DeliveryOutbox{
            turn_id: turn_id,
            session_uri: URI.to_string(uri),
            workspace_uri: URI.to_string(workspace_uri),
            message_ids: [],
            surface_version: nil,
            committed_seq: nil,
            emitted_at: now
          })
      end

      :ok = Ezagent.Socialware.Settlement.backfill_committed_seq!()

      t9 = "#{URI.to_string(uri)}#turn-9"
      t10 = "#{URI.to_string(uri)}#turn-10"

      assert Repo.get_by(DeliveryOutbox, turn_id: t9).committed_seq <
               Repo.get_by(DeliveryOutbox, turn_id: t10).committed_seq

      assert Repo.get_by(DeliveryOutbox, turn_id: t10).surface_version == 2
    end
  end
end
