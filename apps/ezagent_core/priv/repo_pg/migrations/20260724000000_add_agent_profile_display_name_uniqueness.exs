defmodule EzagentCore.Repo.Migrations.AddAgentProfileDisplayNameUniqueness do
  use Ecto.Migration

  @index_name :entity_profiles_agent_workspace_display_name_index
  @agent_uri_predicate "entity_uri ~ '^entity://[^/:?#]+/agent/[^/?#]+$'"

  def up do
    create unique_index(:entity_profiles, [:workspace_uri, :display_name],
             where: @agent_uri_predicate,
             name: @index_name
           )
  end

  def down do
    drop_if_exists(index(:entity_profiles, [:workspace_uri, :display_name], name: @index_name))
  end
end
