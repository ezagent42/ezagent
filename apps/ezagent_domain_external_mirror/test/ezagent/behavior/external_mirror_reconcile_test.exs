defmodule Ezagent.ActionSet.ExternalMirror.ReconcileAfterLoadTest do
  @moduledoc """
  Task #34 — `reconcile_after_load/2` unions DB binding rows with
  the slice after snapshot restore.

  Why this exists: `init_slice/1` reads DB on fresh init, but
  `Ezagent.Kind.Snapshot.load_or_init/3` merges the snapshot OVER
  the fresh state, so DB rows inserted between the last snapshot
  and the next Kind restart are silently lost from the slice. The
  `:handle_continue` reconcile loop then walks an out-of-date
  slice and never spawns workers for the new rows.

  These tests verify the reconcile shape directly (pure function),
  no Kind.Server / supervisor / dispatch wiring — the snapshot
  integration is covered separately via `EzagentCore.Kind.SnapshotTest`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.ExternalMirror
  alias Ezagent.ExternalMirror.BindingRow

  defp session_uri(name \\ "reconcile-test"),
    do: Ezagent.URI.new!("session://system/default/#{name}-#{System.unique_integer([:positive])}")

  defp insert_binding!(session_uri, adapter_id, target_id) do
    {:ok, row} =
      BindingRow.insert(%{
        id: BindingRow.row_id(session_uri, adapter_id, target_id),
        session_uri: URI.to_string(session_uri),
        adapter_id: adapter_id,
        target_id: target_id,
        opts_json: "{}",
        bound_by: "entity://system/user/admin",
        bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        workspace_uri: "workspace://system"
      })

    row
  end

  describe "reconcile_after_load/2" do
    test "empty slice picks up newly-inserted DB row" do
      session = session_uri("empty-slice")
      _row = insert_binding!(session, "feishu", "oc_test_target_a")

      slice = %{bindings: []}
      reconciled = ExternalMirror.reconcile_bindings(session, slice)

      assert length(reconciled.bindings) == 1
      assert hd(reconciled.bindings).adapter_id == "feishu"
      assert hd(reconciled.bindings).target_id == "oc_test_target_a"
    end

    test "existing binding NOT duplicated when DB row matches (idempotence)" do
      session = session_uri("idempotent")
      _row = insert_binding!(session, "feishu", "oc_test_target_b")

      # First reconcile picks up the row.
      slice = %{bindings: []}
      first = ExternalMirror.reconcile_bindings(session, slice)
      assert length(first.bindings) == 1

      # Second reconcile on the same slice — must be a no-op (idempotent).
      second = ExternalMirror.reconcile_bindings(session, first)
      assert length(second.bindings) == 1
      assert second == first
    end

    test "unions snapshot binding with NEW DB row added after snapshot" do
      session = session_uri("union")
      row_a = insert_binding!(session, "feishu", "oc_a")
      slice_a = %{
        binding_id: BindingRow.binding_id(row_a.adapter_id, row_a.target_id),
        adapter_id: "feishu",
        target_id: "oc_a",
        opts: %{},
        bound_by: Ezagent.URI.new!("entity://system/user/admin"),
        bound_at: row_a.bound_at,
        subscription_state: :active
      }

      # Snapshot slice has only the first binding.
      slice = %{bindings: [slice_a]}

      # Now insert a SECOND row — this is the simulated post-snapshot
      # bypass (SQL insert, race, etc.).
      _row_b = insert_binding!(session, "feishu", "oc_b")

      reconciled = ExternalMirror.reconcile_bindings(session, slice)
      assert length(reconciled.bindings) == 2
      target_ids = Enum.map(reconciled.bindings, & &1.target_id) |> Enum.sort()
      assert target_ids == ["oc_a", "oc_b"]
    end

    test "non-URI session arg returns slice unchanged (no crash)" do
      slice = %{bindings: []}
      assert ExternalMirror.reconcile_bindings("not-a-uri", slice) == slice
    end
  end

  describe "cold-load rehydration from an old-shape snapshot lacking :bindings (Track #14)" do
    # Root cause: on a cold-load of an already-created Session, the
    # Lifecycle `__init_slice__` skips `create/1` and lets the snapshot
    # supply the `:external_mirror` state. An OLD-shape snapshot (written
    # before `:bindings` existed, or with an empty `%{}` external_mirror
    # state) rehydrates a state map with NO `:bindings` key. The reconcile
    # head required `%{bindings: existing}`, so it fell through to the
    # non-URI guard clause and returned the `:bindings`-less map verbatim;
    # `activate/2` then raised `KeyError key :bindings` on
    # `reconciled.bindings`. The DB projection (`external_mirror_bindings`)
    # is the SoT — reconcile MUST materialize `:bindings` from it.

    test "reconcile on state WITHOUT :bindings materializes the SoT (no crash)" do
      session = session_uri("old-shape-empty")
      _row = insert_binding!(session, "feishu", "oc_old_shape")

      # Old-shape rehydrated state: the external_mirror slice state is `%{}`
      # — the `:bindings` key never existed in this snapshot.
      reconciled = ExternalMirror.reconcile_bindings(session, %{})

      assert Map.has_key?(reconciled, :bindings)
      assert length(reconciled.bindings) == 1
      assert hd(reconciled.bindings).target_id == "oc_old_shape"
    end

    test "reconcile on state WITHOUT :bindings and no DB rows yields []" do
      session = session_uri("old-shape-norows")

      reconciled = ExternalMirror.reconcile_bindings(session, %{})

      assert reconciled.bindings == []
    end

    test "activate/2 does not crash when rehydrated state lacks :bindings" do
      session = session_uri("old-shape-activate")
      _row = insert_binding!(session, "feishu", "oc_activate")

      # Drives the exact crash site: activate/2 → reconcile_bindings → then
      # `reconciled.bindings` (KeyError pre-fix). activate self-signals via
      # the B2 transport (`Signal.send_after/2`); the test process receives
      # the envelope, proving no raise.
      assert {:ok, %{}, reconciled} =
               ExternalMirror.activate(%{}, %{self_uri: session})

      assert length(reconciled.bindings) == 1

      assert_receive %EzagentActor.Signal{
        kind: :timer,
        payload: {:ezagent_em_reconcile, [_binding]}
      }
    end
  end
end
