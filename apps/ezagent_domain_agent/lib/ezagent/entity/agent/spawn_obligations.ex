defmodule Ezagent.Entity.Agent.SpawnObligations do
  @moduledoc false

  def safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def bind_workspace(worker_uri, workspace_uri) do
    case Ezagent.WorkspaceRegistry.bind(worker_uri, workspace_uri) do
      :ok -> :ok
      other -> other
    end
  end

  def record_lineage(agent_uri, granted_by) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :record, 2) do
      Ezagent.AgentLineage.record(agent_uri, granted_by)
    else
      require Logger

      Logger.debug(
        "Ezagent.Entity.Agent.spawn: AgentLineage registry not loaded; " <>
          "{:spawned_by, _} cap shapes will deny for #{Ezagent.URI.stable_key(agent_uri)}"
      )

      :ok
    end
  end

  def record_lineage_with_status(agent_uri, granted_by) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :record_with_status, 2) do
      Ezagent.AgentLineage.record_with_status(agent_uri, granted_by)
    else
      case record_lineage(agent_uri, granted_by) do
        :ok -> {:ok, %{lineage: :exists, derivation_edge: :exists}}
        {:error, _reason} = error -> error
      end
    end
  end
end
