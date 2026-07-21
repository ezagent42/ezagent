defmodule Ezagent.ProviderConnection.Selector do
  @moduledoc "Authoritative selectable-connection selection for credential operations."
  import Ecto.Query
  alias EzagentCore.Repo
  alias Ezagent.ProviderConnection.Connection

  # Connections that currently own or are acquiring a valid credential pointer
  # and are not in a terminal or pre-binding state. `refresh_required` and
  # `refreshing` may still serve a valid credential (the refresh is a
  # background rotation); `degraded` has a credential with known issues but
  # may still serve reads. Terminal states (revoked/disconnected/failed),
  # the pre-binding `pending_authorization`, and explicitly `expired` are
  # excluded.
  @selectable ~w(active refresh_required refreshing degraded)

  @keys ~w(owner_uri workspace_uri provider_id governed_host execution_identity)a
  @doc "Selects the unique selectable connection matching the exact governed scope."
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
              c.execution_identity == ^identity and c.status in @selectable,
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
