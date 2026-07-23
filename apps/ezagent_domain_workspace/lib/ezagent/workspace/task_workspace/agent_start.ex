defmodule Ezagent.Workspace.TaskWorkspace.AgentStart do
  @moduledoc "Trusted bridge from a ready task workspace to Agent template spawning."

  alias Ezagent.Entity.Agent.TemplateSpawn

  alias Ezagent.Workspace.TaskWorkspace.AgentStart.Ref
  alias Ezagent.Workspace.TaskWorkspace.Store

  @doc "Starts an Agent through the only trusted task-workspace pre-start path."
  @spec start(map(), URI.t(), URI.t(), URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def start(content, instance_uri, spawned_by_uri, workspace_uri, identity)
      when is_map(identity) do
    with {:ok, ref} <- build_ref(identity) do
      with {:ok, _row} <-
             Store.bind_start_intent(ref.provision_id, %{
               agent_uri: URI.to_string(instance_uri),
               provenance_root_uri: URI.to_string(spawned_by_uri),
               workspace_uri: URI.to_string(workspace_uri),
               task_access_uri: URI.to_string(ref.task_access_uri),
               task_uri: URI.to_string(ref.task_uri),
               generation: ref.generation
             }) do
        TemplateSpawn.spawn_from_template_content(
          content,
          instance_uri,
          spawned_by_uri,
          workspace_uri,
          pre_start_ref: ref
        )
      end
    end
  end

  defp build_ref(%{
         provision_id: provision_id,
         task_access_uri: task_access_uri,
         task_uri: task_uri,
         generation: generation
       }) do
    if is_binary(provision_id) and provision_id != "" and match?(%URI{}, task_access_uri) and
         match?(%URI{}, task_uri) and is_integer(generation) and generation > 0 do
      {:ok,
       %Ref{
         provision_id: provision_id,
         task_access_uri: task_access_uri,
         task_uri: task_uri,
         generation: generation
       }}
    else
      {:error, :invalid_task_workspace_start_identity}
    end
  end

  defp build_ref(_identity), do: {:error, :invalid_task_workspace_start_identity}
end
