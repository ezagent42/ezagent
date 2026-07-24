defmodule EzagentCore.Repo.Migrations.AddAgentProfileDisplayNameUniqueness do
  use Ecto.Migration

  def change do
    create unique_index(:entity_profiles, [:workspace_uri, :display_name],
             where: "email IS NULL",
             name: :entity_profiles_agent_workspace_display_name_index
           )
  end
end
