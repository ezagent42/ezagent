defmodule EzagentCore.Repo.Migrations.CreateIdentityCaps do
  use Ecto.Migration

  # #189 / #185 PR-1 (identity-plane cutover step 1, ADDITIVE): the unified
  # per-entity identity-caps store — the generalization of `users.caps_json`
  # to every entity URI. One row per canonical entity URI holds the COMPLETE
  # held-cap set (`caps_json`, serialized `[Capability.to_map/1]`), the
  # explicit identity lifecycle status, and the authenticated provisioning
  # receipt. `kind_cap_authorities` is unchanged (signing keys + generation);
  # this table holds caps + status + receipt.
  #
  # PR-1 writes BOTH the legacy store (users.caps_json / snapshot :identity
  # slice) AND this table (dual-write) and prefers this table on durable
  # reads with legacy fallback (dual-read). The table is NOT authoritative
  # until the atomic cutover PR.
  def change do
    create table(:identity_caps, primary_key: false) do
      add :uri, :string, primary_key: true
      add :caps_json, :text, null: false, default: "[]"
      add :identity_status, :string, null: false, default: "active"
      add :provisioning_receipt, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:identity_caps, :identity_caps_identity_status_check,
             check: "identity_status IN ('active', 'revoked_unprovisioned', 'tombstoned')"
           )

    create index(:identity_caps, [:identity_status])
  end
end
