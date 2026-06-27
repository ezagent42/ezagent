defmodule EzagentCore.Repo.Migrations.RenameAdvisorBehaviorToAgentSoul do
  @moduledoc """
  Rename the default config-cascade KEY `advisor.behavior` → `agent.soul`
  (SPEC `docs/together/2026-06-26/specs/soul-config-key-rename.md`).

  Thin caller of `Ezagent.Socialware.ConfigKeyRename` (the testable rewrite
  logic — see that module's moduledoc for the full rationale: which columns +
  the pointer `id` PK are rewritten, the MANDATORY collision preflight, and the
  **one-time exception to ConfigObject immutability** — this UPDATEs the
  append-only object row's `key` COLUMN, acceptable because it changes a
  routing label, not the `body`, and ids/URIs are untouched).

  Forward-only, non-destructive, idempotent. `down/0` is the exact inverse and
  is valid ONLY inside the coordinated one-shot maintenance window (SPEC §4.5
  strategy 1 — disposable / single-node infra, no multi-node rolling fleet);
  see `ConfigKeyRename`'s rollback limitation.
  """

  use Ecto.Migration

  def up, do: Ezagent.Socialware.ConfigKeyRename.run()

  def down, do: Ezagent.Socialware.ConfigKeyRename.rollback()
end
