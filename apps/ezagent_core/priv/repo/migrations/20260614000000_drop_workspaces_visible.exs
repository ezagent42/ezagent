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

  Without this step, the post-merge boot crashes on the first
  `Workspace.Store.list_all/0` call (the schema declares no
  `:visible` field but the DB column persists, causing an Ecto
  changeset/select mismatch). The crash IS the structural reminder.

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
