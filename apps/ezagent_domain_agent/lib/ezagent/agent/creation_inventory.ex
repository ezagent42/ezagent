defmodule Ezagent.Agent.CreationInventory do
  @moduledoc "Durable, Agent-domain-owned facts about freshly created Agents."

  alias Ezagent.Agent.CreationInventoryEntry
  alias EzagentCore.Repo

  def attempt_id(%URI{} = agent_uri),
    do: "agent-spawn:#{Ezagent.URI.stable_key(agent_uri)}"

  def record(attempt_id, %URI{} = agent_uri, %URI{} = root_uri, %URI{} = workspace_uri)
      when is_binary(attempt_id) and attempt_id != "" do
    attrs = %{
      creation_attempt_id: attempt_id,
      agent_uri: URI.to_string(agent_uri),
      provenance_root_uri: URI.to_string(root_uri),
      workspace_uri: URI.to_string(workspace_uri)
    }

    %CreationInventoryEntry{}
    |> CreationInventoryEntry.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, _entry} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  def member?(attempt_id, %URI{} = agent_uri, %URI{} = _root_uri, %URI{} = workspace_uri) do
    not is_nil(
      Repo.get_by(CreationInventoryEntry,
        creation_attempt_id: attempt_id,
        agent_uri: URI.to_string(agent_uri),
        workspace_uri: URI.to_string(workspace_uri)
      )
    )
  end
end
