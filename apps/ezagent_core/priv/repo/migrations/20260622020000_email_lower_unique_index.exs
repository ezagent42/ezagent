defmodule EzagentCore.Repo.Migrations.EmailLowerUniqueIndex do
  @moduledoc """
  Login email+password (task #87) — email is the login account, so it must be
  unique case-insensitively. `Profile.by_email/1` resolves on `lower(email)`,
  but the original index (20260529000000) is on the RAW `email`. Replace it with
  a partial unique index on `lower(email)` so the DB guard matches the lookup.

  A duplicate-email preflight aborts the migration if any case-folded collisions
  exist (none expected — no production users as of 2026-06-22).
  """
  use Ecto.Migration
  import Ecto.Query

  def up do
    dups =
      EzagentCore.Repo.all(
        from(p in "entity_profiles",
          where: not is_nil(p.email),
          group_by: fragment("lower(?)", p.email),
          having: count(p.entity_uri) > 1,
          select: fragment("lower(?)", p.email)
        )
      )

    if dups != [] do
      raise "duplicate case-folded emails block lower(email) unique index: #{inspect(dups)}"
    end

    drop_if_exists(index(:entity_profiles, [:email], name: :entity_profiles_email_index))

    create(
      unique_index(:entity_profiles, ["lower(email)"],
        name: :entity_profiles_email_lower_index,
        where: "email IS NOT NULL"
      )
    )
  end

  def down do
    drop_if_exists(
      index(:entity_profiles, ["lower(email)"], name: :entity_profiles_email_lower_index)
    )

    create(
      unique_index(:entity_profiles, [:email],
        name: :entity_profiles_email_index,
        where: "email IS NOT NULL"
      )
    )
  end
end
