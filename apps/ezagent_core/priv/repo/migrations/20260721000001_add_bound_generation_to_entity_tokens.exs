defmodule EzagentCore.Repo.Migrations.AddBoundGenerationToEntityTokens do
  use Ecto.Migration

  def change do
    alter table(:entity_tokens) do
      add :bound_generation, :integer
    end
  end
end
