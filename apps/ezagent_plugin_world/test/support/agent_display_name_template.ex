defmodule Ezagent.World.AgentDisplayNameTemplate do
  @moduledoc false

  @behaviour Ezagent.Kind.Template

  @impl true
  def template_name, do: "test.world_profile_display_name"

  @impl true
  def config_dir_namespace, do: "cc"

  @impl true
  def validate(_data), do: :ok

  @impl true
  def instantiate(_name, data, _workspace_uri) do
    agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
    config_dir = Map.fetch!(data, "allocated_config_dir")
    # #201 PR-2 — instantiate-time flavor reads come from the data map
    # (authored by `AgentTemplate.to_template_data/2`), NEVER the global
    # `AgentFlavorAttributes` ETS table.
    flavor = Map.fetch!(data, "flavor")

    respawn_template_data =
      data
      |> Map.put("agent_config_dir", config_dir)
      |> Map.put("flavor", flavor)

    case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, %{
           uri: agent_uri,
           config_dir_path: config_dir,
           template_class: __MODULE__,
           respawn_template_data: respawn_template_data
         }) do
      {:ok, :started, _pid, %{created?: created?}} ->
        :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)

        {:ok, [agent_uri],
         %{
           fresh?: true,
           created?: created?,
           config_dir_path: config_dir,
           respawn_template_data: respawn_template_data
         }}

      {:ok, :already_started, _pid, _receipt} ->
        {:ok, [agent_uri], %{fresh?: false}}

      {:error, {:already_registered, _}} ->
        {:ok, [agent_uri], %{fresh?: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
