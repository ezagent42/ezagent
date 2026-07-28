defmodule EzagentCore.Repo.Migrations.GeneralizeCompositionConsentUriShare do
  @moduledoc """
  URI-share unification (A3) — generalize the composition-consent mechanism so
  URI-share is its LOOSER case (composition = the constrained special case).

  composition consent = two-party (target-owner ISSUE + source-owner STORE)
  approval of a composition BINDING (an installed-Definition edge). URI-share
  consent = the same state machine, but WITHOUT a binding and with the source
  side auto-satisfied (the requester IS the recipient). So:

    * `binding_id` becomes NULLABLE on both consent tables — a URI-share consent
      has no binding. The FK still constrains any non-NULL value (composition
      rows), so referential integrity for composition is unchanged.
    * consents gain nullable `target_uri` / `grantee_uri` — a binding-less
      consent names its target/grantee directly (composition still derives them
      from the binding).
    * consent_commands gain a nullable `consent_id` FK → consents.id — a
      binding-less command references its consent directly (composition commands
      keep referencing via `binding_id`).

  Composition rows/paths are untouched: they still set `binding_id` + both sides.
  """
  use Ecto.Migration

  def up do
    # Drop NOT NULL on binding_id (keeps the FK — a FK permits NULLs).
    execute "ALTER TABLE socialware_composition_consents ALTER COLUMN binding_id DROP NOT NULL"

    execute "ALTER TABLE socialware_composition_consent_commands ALTER COLUMN binding_id DROP NOT NULL"

    alter table(:socialware_composition_consents) do
      # Binding-less (URI-share) consents name their target/grantee directly.
      add :target_uri, :string
      add :grantee_uri, :string
    end

    alter table(:socialware_composition_consent_commands) do
      # Binding-less commands reference their consent directly.
      add :consent_id,
          references(:socialware_composition_consents,
            type: :string,
            column: :id,
            on_delete: :delete_all
          )
    end

    create index(:socialware_composition_consents, [:target_uri, :grantee_uri])
    create index(:socialware_composition_consent_commands, [:consent_id])
  end

  def down do
    drop index(:socialware_composition_consent_commands, [:consent_id])
    drop index(:socialware_composition_consents, [:target_uri, :grantee_uri])

    alter table(:socialware_composition_consent_commands) do
      remove :consent_id
    end

    alter table(:socialware_composition_consents) do
      remove :grantee_uri
      remove :target_uri
    end

    execute "ALTER TABLE socialware_composition_consent_commands ALTER COLUMN binding_id SET NOT NULL"

    execute "ALTER TABLE socialware_composition_consents ALTER COLUMN binding_id SET NOT NULL"
  end
end
