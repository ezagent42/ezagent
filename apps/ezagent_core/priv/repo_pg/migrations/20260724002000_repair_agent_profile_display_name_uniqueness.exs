defmodule EzagentCore.Repo.Migrations.RepairAgentProfileDisplayNameUniqueness do
  use Ecto.Migration

  @index_name :entity_profiles_agent_workspace_display_name_index
  @agent_uri_predicate "entity_uri ~ '^entity://[^/:?#]+/agent/[^/?#]+$'"

  def up do
    replace_with_agent_scoped_index()
  end

  # Rolling this corrective migration back must not restore the unsafe
  # email-null predicate, which also covered non-agent entity profiles.
  def down do
    replace_with_agent_scoped_index()
  end

  defp replace_with_agent_scoped_index do
    drop_if_exists(index(:entity_profiles, [:workspace_uri, :display_name], name: @index_name))

    create unique_index(:entity_profiles, [:workspace_uri, :display_name],
             where: @agent_uri_predicate,
             name: @index_name
           )
  end
end
