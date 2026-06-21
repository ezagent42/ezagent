defmodule EzagentCore.Repo.Migrations.AddMergeClaimToSocialwareAnonBindings do
  use Ecto.Migration

  # anon-user PR-2 — durable login-merge claim. The anon→login merge spans
  # Session Kind state plus DB projections, so the binding row survives as the
  # retry record until convergence is verified and the anon is retired.
  def change do
    alter table(:socialware_anon_bindings) do
      add :merging_to, :string, null: true
      add :merge_state, :string, null: true
    end

    create index(:socialware_anon_bindings, [:merge_state],
             name: :socialware_anon_bindings_merge_state_index
           )
  end
end
