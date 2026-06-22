defmodule EzagentCore.Repo.Migrations.AddEmailVerifiedToUsers do
  @moduledoc """
  Login email+password (task #87) — `email_verified` is the source of truth for
  "this user has proven email ownership", independent of `confirmed` (anon-ness).
  Form login is gated on `email_verified == true`.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:email_verified, :boolean, null: false, default: false)
    end

    # No existing production users (Allen 2026-06-22). Backfill defensively: any
    # pre-existing real (confirmed) user is treated as already-verified so this
    # migration is behavior-preserving for any dev/test rows.
    execute("UPDATE users SET email_verified = TRUE WHERE confirmed = TRUE")
  end

  def down do
    alter table(:users) do
      remove(:email_verified)
    end
  end
end
