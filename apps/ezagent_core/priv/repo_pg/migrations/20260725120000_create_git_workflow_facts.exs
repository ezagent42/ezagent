defmodule EzagentCore.Repo.Migrations.CreateGitWorkflowFacts do
  use Ecto.Migration

  def change do
    create table(:git_workflow_facts, primary_key: false) do
      add :id, :string, null: false, primary_key: true
      add :run_id, :string, null: false
      add :workspace_uri, :string, null: false
      add :workspace_provision_id, :string
      add :deterministic_head_ref, :string
      add :change_digest, :string
      add :expected_base_sha, :string
      add :head_sha, :string
      add :change_request_id, :string
      add :change_request_url, :string
      add :change_request_state, :string
      add :change_request_head_ref, :string
      add :change_request_base_ref, :string
      add :checks_revision, :integer
      add :checks_summary, :string
      add :checks_observed_at, :utc_datetime_usec
      add :reviews_revision, :integer
      add :reviews_summary, :string
      add :reviews_observed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:git_workflow_facts, [:run_id])
    create index(:git_workflow_facts, [:workspace_uri])
  end
end
