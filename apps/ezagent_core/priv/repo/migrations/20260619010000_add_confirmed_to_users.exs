defmodule EzagentCore.Repo.Migrations.AddConfirmedToUsers do
  @moduledoc """
  #154 spec 甲 PR-甲-1 — add a real `confirmed` boolean to users, replacing the
  `anon-` URI name-prefix hack as the source of truth for anon-ness.

  Additive column, default `false`. Backfill: every PRE-EXISTING user is a real
  (confirmed) user EXCEPT the reserved `anon-` mint rows. New rows set `confirmed`
  explicitly — `Users.create/3` → true, `Users.create_read_only/2` → false.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:confirmed, :boolean, null: false, default: false)
    end

    # Backfill existing rows: real users → true; reserved anon mints stay false.
    execute("UPDATE users SET confirmed = TRUE WHERE uri NOT LIKE '%/user/anon-%'")
  end

  def down do
    alter table(:users) do
      remove(:confirmed)
    end
  end
end
