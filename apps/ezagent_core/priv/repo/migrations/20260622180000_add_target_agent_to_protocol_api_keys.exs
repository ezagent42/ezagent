defmodule EzagentPluginProtocolApi.Repo.Migrations.AddTargetAgentToProtocolApiKeys do
  use Ecto.Migration

  def change do
    alter table(:protocol_api_keys) do
      add :target_agent, :string, default: nil
    end
  end
end
