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
