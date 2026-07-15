defmodule Ezagent.Agent.CreationInventory do
  @moduledoc "Durable, Agent-domain-owned facts about freshly created Agents."

  import Ecto.Query

  alias Ezagent.Agent.CreationInventoryEntry
  alias EzagentCore.Repo

  @doc false
  def new_attempt_id, do: Ecto.UUID.generate()

  @doc false
  def record(attempt_id, %URI{} = agent_uri, %URI{} = root_uri, %URI{} = workspace_uri)
      when is_binary(attempt_id) and attempt_id != "" do
    attrs = %{
      creation_attempt_id: attempt_id,
      agent_uri: URI.to_string(agent_uri),
      provenance_root_uri: URI.to_string(root_uri),
      workspace_uri: URI.to_string(workspace_uri)
    }

    case Repo.get_by(CreationInventoryEntry,
           creation_attempt_id: attempt_id,
           agent_uri: URI.to_string(agent_uri)
         ) do
      %CreationInventoryEntry{} = existing ->
        if exact_fact?(existing, attrs), do: :ok, else: {:error, :creation_fact_conflict}

      nil ->
        %CreationInventoryEntry{}
        |> CreationInventoryEntry.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, _entry} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc false
  def member?(attempt_id, %URI{} = agent_uri, %URI{} = _root_uri, %URI{} = workspace_uri) do
    case Repo.get_by(CreationInventoryEntry,
           creation_attempt_id: attempt_id,
           agent_uri: URI.to_string(agent_uri),
           workspace_uri: URI.to_string(workspace_uri)
         ) do
      %CreationInventoryEntry{provenance_root_uri: parent} ->
        case Ezagent.AgentLineage.lookup(agent_uri) do
          {:ok, current_parent} -> URI.to_string(current_parent) == parent
          :error -> false
        end

      nil ->
        false
    end
  end

  @doc false
  def find_attempt(%URI{} = agent_uri, %URI{} = workspace_uri) do
    query =
      from(e in CreationInventoryEntry,
        where: e.agent_uri == ^URI.to_string(agent_uri),
        where: e.workspace_uri == ^URI.to_string(workspace_uri),
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
      )

    case Repo.one(query) do
      %CreationInventoryEntry{creation_attempt_id: attempt_id} -> {:ok, attempt_id}
      nil -> {:error, :creation_attempt_not_found}
    end
  end

  defp exact_fact?(entry, attrs) do
    entry.provenance_root_uri == attrs.provenance_root_uri and
      entry.workspace_uri == attrs.workspace_uri
  end
end
