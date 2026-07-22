defmodule Ezagent.Workspace.TaskWorkspace.LaunchAuthority do
  @moduledoc "Trusted one-use launch-context issuer backed by durable Provision claims."

  use GenServer

  @behaviour Ezagent.Agent.LaunchAuthority

  alias Ezagent.Workspace.TaskWorkspace.{Provision, Store}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Issues an opaque handle bound to one provision id and start claim."
  @spec issue(pos_integer(), String.t()) :: reference() | {:error, :invalid_start_claim}
  def issue(id, claim) when is_integer(id) and id > 0 and is_binary(claim) and claim != "" do
    GenServer.call(__MODULE__, {:issue, id, claim})
  end

  def issue(_id, _claim), do: {:error, :invalid_start_claim}

  @impl true
  def resolve_launch(handle, agent_uri),
    do: GenServer.call(__MODULE__, {:resolve, handle, agent_uri})

  @impl true
  def acknowledge_launch({handle, claim}) do
    GenServer.call(__MODULE__, {:acknowledge, handle, claim})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:issue, id, claim}, _from, entries) do
    handle = make_ref()
    entry = %{id: id, start_claim_token: claim, consumed?: false}
    {:reply, handle, Map.put(entries, handle, entry)}
  end

  def handle_call({:resolve, handle, agent_uri}, _from, entries) do
    reply =
      case Map.fetch(entries, handle) do
        {:ok, %{consumed?: true}} -> {:error, :launch_context_consumed}
        {:ok, entry} -> resolve_entry(entry, handle, agent_uri)
        :error -> {:error, :invalid_launch_context}
      end

    {:reply, reply, entries}
  end

  def handle_call({:acknowledge, handle, claim}, _from, entries) do
    case Map.fetch(entries, handle) do
      {:ok, %{consumed?: true}} ->
        {:reply, {:error, :launch_context_consumed}, entries}

      {:ok, %{start_claim_token: ^claim} = entry} ->
        {:reply, :ok, Map.put(entries, handle, %{entry | consumed?: true})}

      _other ->
        {:reply, {:error, :invalid_launch_issuer_ref}, entries}
    end
  end

  defp resolve_entry(entry, handle, agent_uri) do
    with %Provision{} = row <- Store.get(entry.id),
         :ok <- current_claim(row, entry.start_claim_token),
         {:ok, stored_agent} <- parse_uri(row.agent_uri),
         true <- stored_agent == agent_uri,
         {:ok, root} <- parse_uri(row.provenance_root_uri),
         {:ok, workspace} <- parse_uri(row.workspace_uri),
         :ok <- valid_identity(row.creation_attempt_id, stored_agent, root, workspace) do
      {:ok,
       %{
         attempt_id: row.creation_attempt_id,
         agent_uri: stored_agent,
         root_uri: root,
         workspace_uri: workspace,
         issuer_ref: {handle, entry.start_claim_token}
       }}
    else
      nil -> {:error, :launch_claim_missing}
      false -> {:error, :launch_agent_uri_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_claim(
         %Provision{status: :starting, start_claim_token: claim, start_lease_until: lease},
         claim
       )
       when is_struct(lease, DateTime) do
    if DateTime.compare(lease, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :launch_claim_expired}
  end

  defp current_claim(%Provision{status: :starting}, _claim), do: {:error, :launch_claim_replaced}
  defp current_claim(%Provision{}, _claim), do: {:error, :launch_claim_inactive}

  defp valid_identity(attempt, agent, root, workspace)
       when is_binary(attempt) and attempt != "" do
    if Ezagent.URI.scheme?(agent, :entity) and Ezagent.URI.type?(agent, :agent) and
         Ezagent.URI.workspace_of(agent) == workspace and
         Ezagent.URI.workspace_of(root) == workspace,
       do: :ok,
       else: {:error, :invalid_launch_identity}
  end

  defp valid_identity(_attempt, _agent, _root, _workspace), do: {:error, :invalid_launch_identity}

  defp parse_uri(value) when is_binary(value) and value != "" do
    case Ezagent.URI.parse(value) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:error, _reason} -> {:error, :invalid_launch_identity}
    end
  end

  defp parse_uri(_value), do: {:error, :invalid_launch_identity}
end
