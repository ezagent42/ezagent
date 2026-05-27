defmodule Ezagent.ExternalMirror.BindingRowTest do
  @moduledoc """
  Unit tests for `Ezagent.ExternalMirror.BindingRow` — the projection
  schema for `external_mirror_bindings`.

  Task #53 (2026-05-27) regression coverage: `delete_by_id/1` and
  `delete_by_natural_key/3` now return `{:ok, :deleted | :not_found}
  | {:error, %Ecto.Changeset{}}` (previously bare `:ok` for all
  three cases). This change is what lets `Behavior.ExternalMirror.
  do_unbind/4` detect projection desync and refuse the unbind
  rather than silently lying to the caller.

  The 2026-05-27 02:53 Feishu repro symptom — facade returned
  `{:ok, %{ok: true, unbound: true}}` but DB row stayed —
  surfaced because the old `delete_by_id/1` returned `:ok` even
  when `Repo.get` found nothing. These tests pin the new shape
  so a future "simplification" can't regress it.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.BindingRow

  describe "delete_by_id/1 — task #53 return shape" do
    test "{:ok, :deleted} when row existed" do
      attrs = fixture_attrs("session://default/system/em-del-1", "feishu", "oc_a")
      {:ok, row} = BindingRow.insert(attrs)

      assert {:ok, :deleted} = BindingRow.delete_by_id(row.id)

      # And the row is actually gone.
      assert nil == EzagentCore.Repo.get(BindingRow, row.id)
    end

    test "{:ok, :not_found} when id is unknown — does NOT return bare :ok" do
      assert {:ok, :not_found} = BindingRow.delete_by_id("does-not-exist")
    end
  end

  describe "delete_by_natural_key/3 — task #53 return shape" do
    test "{:ok, :deleted} for an existing (session, adapter, target) triple" do
      session_uri = URI.parse("session://default/system/em-nk-1")
      attrs = fixture_attrs(URI.to_string(session_uri), "feishu", "oc_nk_a")
      {:ok, _row} = BindingRow.insert(attrs)

      assert {:ok, :deleted} =
               BindingRow.delete_by_natural_key(session_uri, "feishu", "oc_nk_a")
    end

    test "{:ok, :not_found} for an unbound triple — surfaces desync" do
      session_uri = URI.parse("session://default/system/em-nk-missing")

      assert {:ok, :not_found} =
               BindingRow.delete_by_natural_key(session_uri, "feishu", "oc_missing")
    end

    test "delete is session-scoped — other sessions' rows survive" do
      session_a = URI.parse("session://default/system/em-nk-a")
      session_b = URI.parse("session://default/system/em-nk-b")
      shared_target = "oc_shared"

      {:ok, row_a} =
        BindingRow.insert(fixture_attrs(URI.to_string(session_a), "feishu", shared_target))

      {:ok, row_b} =
        BindingRow.insert(fixture_attrs(URI.to_string(session_b), "feishu", shared_target))

      # Distinct hashes.
      assert row_a.id != row_b.id

      assert {:ok, :deleted} =
               BindingRow.delete_by_natural_key(session_a, "feishu", shared_target)

      # session_a's row gone; session_b's row survives.
      assert nil == EzagentCore.Repo.get(BindingRow, row_a.id)
      assert %BindingRow{} = EzagentCore.Repo.get(BindingRow, row_b.id)
    end

    # codex PR #418 r1 HIGH regression (2026-05-27): the prior
    # implementation looked up rows by their hashed `:id` value
    # (`row_id/3` of the natural key). That fails for any row whose
    # stored `:id` was derived from a DIFFERENT stringification of
    # `session_uri` than the current call uses — and the 2026-06-13
    # `data_migrate_default_to_system_uris` migration is one such
    # drift source (it rewrites `session_uri` without recomputing
    # `:id`). Post-fix, `delete_by_natural_key/3` deletes by the
    # ACTUAL natural-key columns, so it works regardless of
    # `:id` drift.
    test "deletes even when stored :id does not match the current row_id/3 hash" do
      session_uri = URI.parse("session://system/system/em-nk-drift")
      attrs = fixture_attrs(URI.to_string(session_uri), "feishu", "oc_drift")

      # Manufacture the drift: overwrite the row's `:id` with the
      # hash of a DIFFERENT URI form (simulating the
      # default-to-system migration's
      # `UPDATE … SET session_uri = REPLACE(…)` without recomputing
      # `:id`).
      pre_migration_uri = URI.parse("session://default/system/em-nk-drift")
      drifted_id = BindingRow.row_id(pre_migration_uri, "feishu", "oc_drift")
      attrs = %{attrs | id: drifted_id}

      {:ok, _row} = BindingRow.insert(attrs)

      # Sanity: looking up by the CURRENT row_id misses (the bug).
      current_id = BindingRow.row_id(session_uri, "feishu", "oc_drift")
      assert drifted_id != current_id
      assert nil == EzagentCore.Repo.get(BindingRow, current_id)

      # But natural-key delete still finds + deletes the row.
      assert {:ok, :deleted} =
               BindingRow.delete_by_natural_key(session_uri, "feishu", "oc_drift")

      # Confirm gone.
      assert nil == EzagentCore.Repo.get(BindingRow, drifted_id)
    end
  end

  # ----- helpers -----------------------------------------------------------

  defp fixture_attrs(session_uri_str, adapter_id, target_id) do
    session_uri = URI.parse(session_uri_str)

    workspace_uri =
      try do
        Ezagent.Persistence.workspace_uri_for!(session_uri)
      rescue
        # Workspace resolution may not be wired for these synthetic
        # URIs in the unit-test scope; fall back to a literal value
        # that satisfies validate_required.
        _ -> "workspace://system"
      end

    %{
      id: BindingRow.row_id(session_uri, adapter_id, target_id),
      session_uri: session_uri_str,
      adapter_id: adapter_id,
      target_id: target_id,
      opts_json: "{}",
      bound_by: "entity://user/system/admin",
      bound_at: DateTime.utc_now(),
      workspace_uri: workspace_uri
    }
  end
end
