defmodule EzagentDomainAgent.TestSupport.ProfileFailureTemplate do
  @moduledoc false

  @behaviour Ezagent.Kind.Template

  @namespace "profile-failure"

  @impl true
  def template_name, do: "test.profile_failure_agent"

  @impl true
  def config_dir_namespace, do: @namespace

  @impl true
  def validate(_data), do: :ok

  @impl true
  def instantiate(_name, data, _workspace_uri) do
    agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
    config_dir = Map.fetch!(data, "allocated_config_dir")
    workspace = Ezagent.URI.workspace_name!(agent_uri)
    source_uri = Ezagent.URI.agent(workspace, "profile-failure-source")

    with :ok <- File.write(Path.join(config_dir, "materialized"), "profile failure fixture"),
         {:ok, _grant} <-
           Ezagent.Credential.GrantRow.insert(%{
             agent_uri: URI.to_string(agent_uri),
             credential_source_uri: URI.to_string(source_uri),
             approved_by: URI.to_string(Ezagent.Entity.User.admin_uri()),
             approved_scope: URI.to_string(source_uri),
             version: 1
           }),
         # #201 PR-1/PR-3 — spawn through the receipt so the chokepoint gates
         # this fixture's grant on the core logical-create verdict like any
         # other credential-carrying Template Class.
         {:ok, :started, _pid, %{created?: created?}} <-
           Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, %{
             uri: agent_uri,
             config_dir_path: config_dir,
             template_class: __MODULE__,
             respawn_template_data: data
           }) do
      {:ok, [agent_uri],
       %{
         fresh?: true,
         created?: created?,
         config_dir_path: config_dir,
         respawn_template_data: data
       }}
    end
  end

  @impl true
  def list_extensions(_config_dir), do: {:ok, []}

  @impl true
  def toggle_extension(_config_dir, _extension_id, _enabled?), do: :ok

  @impl true
  def destroy_config_dir(agent_uri, config_dir) do
    if Ezagent.Sandbox.ConfigDir.safe_to_destroy?(config_dir, agent_uri, @namespace) do
      case File.rm_rf(config_dir) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    else
      {:error, :unsafe_config_dir}
    end
  end
end
