defmodule EzagentCore.Repo.Migrations.WorkspaceMagicLinkRules do
  @moduledoc """
  SPEC 2026-05-24 v2 PR-A (Allen) — workspace-scoped magic-link rules.

  Replaces the standalone `registration_domains` AppSetting (which is
  a flat global allow-list) with **per-workspace rules**. A workspace
  may have many rules (OR-combined): e.g. workspace "h2oslabs" accepts
  both `@h2oslabs.com` AND `@h2oslabs.io`.

  OQ-V2-2 decision (Allen): separate TABLE rather than JSON column.
  Lets admin add/remove individual rules without rewriting JSON,
  and supports the OQ-V2-3 "check at both send AND click time"
  semantics cheaply (one SELECT per check).

  Rule types (`rule_type` column):
  - `"domain"` — `rule_value` is the bare domain (e.g. `"h2oslabs.com"`)
  - `"user_list"` — `rule_value` is the literal email (one row per
    allowed user; the LV form expands a comma-separated input into
    multiple rows on save)
  - `"invite_only"` — `rule_value` is the inviter's email (the workspace
    accepts an emailed invite from the inviter to a specific recipient;
    PR-D wires the admin invite UI)

  An email matches a workspace when ANY rule on that workspace matches.
  """

  use Ecto.Migration

  def change do
    create table(:workspace_magic_link_rules) do
      add :workspace_uri, :string, null: false
      add :rule_type, :string, null: false
      add :rule_value, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    # Lookup pattern: "does this workspace accept this email?"
    # → SELECT * WHERE workspace_uri = ? AND rule_value = ?
    create index(:workspace_magic_link_rules, [:workspace_uri])

    # Reverse lookup: "which workspaces accept emails from this domain?"
    # → SELECT * WHERE rule_type = 'domain' AND rule_value = ?
    # Used by send-side gate (codex OQ-V2-3 — both send+click checks).
    create index(:workspace_magic_link_rules, [:rule_type, :rule_value])

    # No FK to workspaces table — the workspaces table is the
    # operational source of truth, but `Workspace.delete/1` (in the
    # rare case it runs) is responsible for the cascade. Adding a FK
    # would require a JOIN on every rule check; the index above is
    # the access path that matters.
  end
end
