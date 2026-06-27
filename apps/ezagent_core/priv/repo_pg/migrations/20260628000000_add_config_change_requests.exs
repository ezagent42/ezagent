defmodule EzagentCore.Repo.Migrations.AddConfigChangeRequests do
  @moduledoc """
  Minimal CR (change-request) config governance — the ONLY new state on top of
  the shipped ConfigStore + sandbox-materialization primitives.

  Two tables in the identity domain (beside `socialware_config_*`), both
  per-tenant (invariant #14 — `workspace_uri NOT NULL`):

    * `socialware_config_change_requests` — the draft envelope. One ACTIVE
      (`open`) CR per `(workspace_uri, subject_uri)` (partial unique index).
    * `socialware_config_change_items` — a staged delta referencing an
      ALREADY-WRITTEN immutable `ConfigObject` (`staged_object_id`) with no
      pointer aimed at it yet. `published_prev_object_id` is the durable
      per-slot rollback target recorded at publish (SPEC §3.2 / §4.5).
  """

  use Ecto.Migration

  def change do
    create table(:socialware_config_change_requests, primary_key: false) do
      add :id, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :subject_uri, :string, null: false
      add :status, :string, null: false
      add :opened_by, :string, null: false
      add :published_by, :string
      add :published_turn_id, :string
      add :title, :string
      add :note, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:socialware_config_change_requests, [:workspace_uri])
    create index(:socialware_config_change_requests, [:subject_uri])

    # One ACTIVE (open) CR per agent-subject: two concurrent open CRs would
    # race the same pointers at publish. Partial unique on status='open'.
    create unique_index(
             :socialware_config_change_requests,
             [:workspace_uri, :subject_uri],
             where: "status = 'open'",
             name: :socialware_config_change_requests_one_open_per_subject
           )

    create table(:socialware_config_change_items, primary_key: false) do
      add :id, :string, primary_key: true

      add :change_request_id,
          references(:socialware_config_change_requests,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :workspace_uri, :string, null: false
      add :layer, :string, null: false
      add :key, :string, null: false
      add :staged_object_id, :string, null: false
      add :base_object_id, :string
      add :published_prev_object_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:socialware_config_change_items, [:change_request_id])
    create index(:socialware_config_change_items, [:workspace_uri])

    # One staged item per slot per CR; re-staging the same slot replaces
    # `staged_object_id` (points at a newer immutable object).
    create unique_index(
             :socialware_config_change_items,
             [:change_request_id, :layer, :key],
             name: :socialware_config_change_items_unique_slot
           )
  end
end
