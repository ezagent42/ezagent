defmodule EzagentCore.Repo.Migrations.PrEm6DropFeishuSessionBindings do
  @moduledoc """
  PR-EM-6 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-6) — drop the retired `feishu_session_bindings` table.

  Replaced by `external_mirror_bindings` (PR-EM-3 §7.1) — the generic
  ExternalMirror Domain projection table. The Feishu plugin's
  retired `EzagentPluginFeishu.SessionBinding` module read/wrote
  this table; that module is deleted in this PR along with the
  one-off `Behavior.FeishuOutbound` outbound path.

  ## codex r1 CRIT fix (2026-05-25) — fail-closed on un-migrated rows

  Pre-r1 fix this migration was an unconditional `drop_if_exists`.
  Because the legacy → generic data copy is in a SEPARATE Mix task
  (`mix ezagent.external_mirror.migrate_feishu_bindings`), a normal
  `mix ecto.migrate` would silently delete every existing
  chat_id-to-session binding — inbound Feishu replies would return
  `:no_chat_binding` and outbound workers would never spawn for
  those chats. Pure data loss.

  The fixed migration enforces fail-closed:

  1. If `feishu_session_bindings` does NOT exist (fresh install or
     already dropped) → no-op success.
  2. If `feishu_session_bindings` exists AND every enabled row's
     `chat_id` has a matching row in `external_mirror_bindings`
     keyed by `adapter_id='feishu' AND target_id=chat_id AND
     session_uri=legacy.session_uri` → safe to drop, proceed.
  3. If `feishu_session_bindings` exists AND there are unmigrated
     enabled rows → RAISE with a message instructing the operator
     to run `mix ezagent.external_mirror.migrate_feishu_bindings`
     first. The migration fails closed; `mix ecto.migrate` aborts;
     no data is lost.

  This is the structural fix per `feedback_let_it_crash_no_workarounds`:
  the data-loss risk surfaces via a hard error at the destructive
  step, not a runtime warning to scroll past.

  ## Operator runbook

      mix ezagent.external_mirror.migrate_feishu_bindings  # populate new table
      mix ecto.migrate                                       # drop old table

  Greenfield installs (where `feishu_session_bindings` was never
  created — i.e. the PR-144 create-migration was never applied)
  skip the check entirely.
  """

  use Ecto.Migration

  def change do
    if legacy_table_exists?() do
      assert_all_rows_migrated!()
    end

    drop_if_exists(table(:feishu_session_bindings))
  end

  defp legacy_table_exists? do
    sql = """
    SELECT name FROM sqlite_master
     WHERE type = 'table' AND name = 'feishu_session_bindings'
    """

    case Ecto.Adapters.SQL.query!(EzagentCore.Repo, sql, []) do
      %{rows: []} -> false
      %{rows: _} -> true
    end
  rescue
    _ -> false
  end

  defp assert_all_rows_migrated! do
    unmigrated = unmigrated_rows()

    if unmigrated != [] do
      details =
        unmigrated
        |> Enum.map(fn [chat_id, session_uri] ->
          "  - chat_id=#{chat_id} session_uri=#{session_uri}"
        end)
        |> Enum.join("\n")

      raise """
      PR-EM-6 destructive migration aborted: #{length(unmigrated)} row(s) in
      `feishu_session_bindings` have NOT been migrated to
      `external_mirror_bindings` yet:

      #{details}

      Run the migration mix task BEFORE applying this Ecto migration:

          mix ezagent.external_mirror.migrate_feishu_bindings

      Then re-run `mix ecto.migrate`. The task is idempotent —
      already-migrated rows are no-ops.

      (codex r1 CRIT fix 2026-05-25 — fail-closed instead of silently
      deleting live operator bindings.)
      """
    end

    :ok
  end

  # Rows in `feishu_session_bindings` (enabled=1) that have NO
  # matching row in `external_mirror_bindings` keyed by
  # adapter_id='feishu', target_id=chat_id, session_uri=session_uri.
  defp unmigrated_rows do
    sql = """
    SELECT f.chat_id, f.session_uri
      FROM feishu_session_bindings f
      LEFT JOIN external_mirror_bindings e
        ON e.adapter_id = 'feishu'
       AND e.target_id  = f.chat_id
       AND e.session_uri = f.session_uri
     WHERE f.enabled = 1
       AND e.id IS NULL
    """

    %{rows: rows} = Ecto.Adapters.SQL.query!(EzagentCore.Repo, sql, [])
    rows
  end
end
