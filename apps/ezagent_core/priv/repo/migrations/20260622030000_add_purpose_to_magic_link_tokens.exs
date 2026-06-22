defmodule EzagentCore.Repo.Migrations.AddPurposeToMagicLinkTokens do
  @moduledoc """
  Login email+password (task #87) — one-time tokens gain a `purpose`
  (`login` | `confirm` | `reset`). Each consumer enforces its own purpose so a
  confirm/reset token can never be replayed at the magic-link login endpoint
  (which only accepts `:login`). (Codex plan-review #3.)

  Additive column, default "login" (magic-link login is retained, so existing
  rows + the default keep working).
  """
  use Ecto.Migration

  def up do
    alter table(:magic_link_tokens) do
      add(:purpose, :string, null: false, default: "login")
    end
  end

  def down do
    alter table(:magic_link_tokens) do
      remove(:purpose)
    end
  end
end
