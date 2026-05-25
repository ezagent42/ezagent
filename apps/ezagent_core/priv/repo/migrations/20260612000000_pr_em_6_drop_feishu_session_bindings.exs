defmodule EzagentCore.Repo.Migrations.PrEm6DropFeishuSessionBindings do
  @moduledoc """
  PR-EM-6 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-6) — drop the retired `feishu_session_bindings` table.

  Replaced by `external_mirror_bindings` (PR-EM-3 §7.1) — the generic
  ExternalMirror Domain projection table. The Feishu plugin's
  retired `EzagentPluginFeishu.SessionBinding` module read/wrote
  this table; that module is deleted in this PR along with the
  one-off `Behavior.FeishuOutbound` outbound path.

  ## Migration of existing rows

  Operators with populated `feishu_session_bindings` rows should run
  `mix ezagent.external_mirror.migrate_feishu_bindings` BEFORE
  applying this migration. The mix task reads the table via plain
  SQL (no dep on the deleted SessionBinding module), writes each row
  into `external_mirror_bindings` via
  `Ezagent.ExternalMirror.BindingRow.insert/1`, and idempotently
  spawns the per-binding Worker via
  `Ezagent.ExternalMirror.WorkerSpawn.spawn/4`.

  Per Allen 2026-05-24 "no migration / no back-compat" guidance on
  the SPEC — fresh installs simply never see the table. The dev DB
  is the only environment where the table is populated; the mix
  task is the operator-driven bridge for that one DB.

  ## Greenfield posture

  Per `feedback_let_it_crash_no_workarounds` — this migration is
  destructive (no rollback rebuild path). The table is dropped
  entirely; reverting PR-EM-6 would re-create it via the prior
  migration's `change/0`.
  """

  use Ecto.Migration

  def change do
    # `DROP TABLE IF EXISTS` keeps the migration idempotent — fresh
    # installs (where the prior PR-144 migration has been deleted
    # along with this PR) just skip the drop. Re-running on an
    # already-dropped DB is also a no-op.
    drop_if_exists(table(:feishu_session_bindings))
  end
end
