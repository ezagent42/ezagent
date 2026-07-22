defmodule EzagentDomainInstanceMessage.SessionCreator.Derivation do
  @moduledoc false

  alias Ezagent.Provenance.DerivationEdges

  @doc false
  @spec record(URI.t(), {URI.t(), URI.t(), URI.t()}) :: :ok | {:error, term()}
  def record(session_uri, {owner_uri, workspace_uri, template_uri}) do
    attempt_id = DerivationEdges.new_attempt_id()

    [
      {owner_uri, :created_by},
      {workspace_uri, :workspace_ownership},
      {template_uri, :parent_template}
    ]
    |> Enum.reduce_while(:ok, fn {parent_uri, edge_kind}, :ok ->
      case DerivationEdges.record_derivation_edge(
             session_uri,
             parent_uri,
             edge_kind,
             attempt_id
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
