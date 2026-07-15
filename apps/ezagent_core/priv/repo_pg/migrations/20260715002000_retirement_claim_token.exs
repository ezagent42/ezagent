defmodule EzagentCore.Repo.Migrations.RetirementClaimToken do
  use Ecto.Migration

  def change do
    alter table(:agent_retirement_obligations) do
      add :claim_token, :text
    end
  end
end
