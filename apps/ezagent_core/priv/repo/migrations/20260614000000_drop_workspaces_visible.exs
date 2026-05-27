defmodule EzagentCore.Repo.Migrations.DropWorkspacesVisible do
  @moduledoc """
  SPEC 2026-05-27-workspace-cap-based-visibility §4.1 — DROP the
  `workspaces.visible` column.

  Visibility is now cap-derived via
  `Ezagent.Workspace.list_workspaces_for/2` (membership +
  cap-scope branches, with admin shortcut via the 4-predicate UNION
  in `Ezagent.Identity.AdminAuthority.admin?/2`). The field-based
  flag is no longer used by any code path.

  ## HUMAN-REQUIRED step

  Per `feedback_destructive_migration_anti_pattern`, a subagent
  MUST NOT run `mix ecto.migrate` against a dev DB that a running
  `phx.server` is using. The operator runs this migration manually:

      # 1. Stop phx.server (Ctrl+C twice)
      # 2. mix ecto.migrate  (or MIX_ENV=dev mix ecto.migrate)
      # 3. Restart phx.server

  ## Important: NO automatic boot-time crash

  Codex r1 review (2026-05-27) corrected the SPEC's OQ-6 premise:
  the post-merge boot DOES NOT crash automatically if the operator
  forgets to migrate. Ecto's `Repo.all(from w in __MODULE__)`
  selects schema fields explicitly (`SELECT w0.id, w0.name, ...`),
  so the EXTRA `visible` column in the DB is silently ignored.
  Inserts also continue to work because the old column has
  `NOT NULL DEFAULT true`.

  This means the operator MUST remember to run the migration —
  the "structural reminder via boot crash" promised in the SPEC's
  §4.1 + OQ-6 does not materialize. Follow-up SPEC amendment
  needed to reflect this. Today the safety net is: this commit's
  body + the PR description flagging `human-required:db-migration`
  + this moduledoc.

  ## Rollback

  Reverting the merge commit restores `field :visible, :boolean,
  default: true` in the schema. The operator must then run
  `MIX_ENV=dev mix ecto.rollback --step 1` to restore the column.
  Two-step revert (code + DB) — per
  `feedback_let_it_crash_no_workarounds`.
  """
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      remove :visible, :boolean, null: false, default: true
    end
  end
end
