defmodule Ezagent.Agent.CreationInventory do
  @moduledoc "Durable, Agent-domain-owned facts about freshly created Agents."

  import Ecto.Query

  alias Ezagent.Agent.CreationInventoryEntry
  alias EzagentCore.Repo

  @doc false
  def new_attempt_id, do: Ecto.UUID.generate()

  @doc false
  @spec record_exact(module(), String.t(), URI.t(), URI.t(), URI.t()) ::
          {:ok, :inserted | :exists} | {:error, term()}
  def record_exact(
        repo,
        attempt_id,
        %URI{} = agent_uri,
        %URI{} = root_uri,
        %URI{} = workspace_uri
      )
      when is_atom(repo) and is_binary(attempt_id) and attempt_id != "" do
    attrs = exact_attrs(attempt_id, agent_uri, root_uri, workspace_uri)
    now = DateTime.utc_now()

    case repo.insert_all(
           CreationInventoryEntry,
           [Map.merge(attrs, %{inserted_at: now, updated_at: now})],
           on_conflict: :nothing,
           conflict_target: [:creation_attempt_id, :agent_uri]
         ) do
      {1, _} -> {:ok, :inserted}
      {0, _} -> classify_existing(repo, attrs)
    end
  end

  @doc false
  @spec exact(String.t(), URI.t(), URI.t(), URI.t()) ::
          {:ok, CreationInventoryEntry.t()}
          | {:error, :creation_attempt_not_found | :creation_fact_conflict}
  def exact(attempt_id, %URI{} = agent_uri, %URI{} = root_uri, %URI{} = workspace_uri)
      when is_binary(attempt_id) and attempt_id != "" do
    attrs = exact_attrs(attempt_id, agent_uri, root_uri, workspace_uri)

    case Repo.get_by(CreationInventoryEntry,
           creation_attempt_id: attrs.creation_attempt_id,
           agent_uri: attrs.agent_uri
         ) do
      %CreationInventoryEntry{} = entry ->
        if exact_fact?(entry, attrs),
          do: {:ok, entry},
          else: {:error, :creation_fact_conflict}

      nil ->
        {:error, :creation_attempt_not_found}
    end
  end

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

  defp classify_existing(repo, attrs) do
    case repo.get_by(CreationInventoryEntry,
           creation_attempt_id: attrs.creation_attempt_id,
           agent_uri: attrs.agent_uri
         ) do
      %CreationInventoryEntry{} = entry ->
        if exact_fact?(entry, attrs),
          do: {:ok, :exists},
          else: {:error, :creation_fact_conflict}

      nil ->
        {:error, :creation_fact_conflict}
    end
  end

  defp exact_attrs(attempt_id, agent_uri, root_uri, workspace_uri) do
    %{
      creation_attempt_id: attempt_id,
      agent_uri: URI.to_string(agent_uri),
      provenance_root_uri: URI.to_string(root_uri),
      workspace_uri: URI.to_string(workspace_uri)
    }
  end
end
