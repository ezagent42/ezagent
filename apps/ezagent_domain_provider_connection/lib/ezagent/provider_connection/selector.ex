defmodule Ezagent.ProviderConnection.Selector do
  @moduledoc "Authoritative active-connection selection."
  import Ecto.Query
  alias EzagentCore.Repo
  alias Ezagent.ProviderConnection.Connection

  @keys ~w(owner_uri workspace_uri provider_id governed_host execution_identity)a
  @doc "Selects the unique active connection matching the exact governed scope."
  def select(scope) when is_map(scope) do
    with :ok <- exact_keys(scope),
         {:ok, owner} <- fetch(scope, :owner_uri),
         {:ok, workspace} <- fetch(scope, :workspace_uri),
         {:ok, provider} <- fetch(scope, :provider_id),
         {:ok, host} <- fetch(scope, :governed_host),
         {:ok, identity} <- fetch(scope, :execution_identity) do
      Repo.all(
        from(c in Connection,
          where:
            c.owner_uri == ^owner and c.workspace_uri == ^workspace and
              c.provider_id == ^provider and c.governed_host == ^host and
              c.execution_identity == ^identity and c.status == "active",
          order_by: [desc: c.connection_version, asc: c.connection_id],
          limit: 2
        )
      )
      |> case do
        [] -> {:error, :connection_not_found}
        [connection] -> {:ok, connection}
        [_first, _second] -> {:error, :connection_ambiguous}
      end
    end
  end

  def select(_), do: {:error, :invalid_subject}

  defp exact_keys(scope),
    do:
      if(Map.keys(scope) |> Enum.sort() == Enum.sort(@keys),
        do: :ok,
        else: {:error, :invalid_subject}
      )

  defp fetch(scope, key),
    do:
      if(is_binary(scope[key]) and scope[key] != "",
        do: {:ok, scope[key]},
        else: {:error, :invalid_subject}
      )
end
