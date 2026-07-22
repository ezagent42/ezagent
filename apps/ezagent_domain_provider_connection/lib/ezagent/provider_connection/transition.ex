defmodule Ezagent.ProviderConnection.Transition do
  @moduledoc "Closed legal transition graph for provider connections."
  @edges MapSet.new([
           {:pending_authorization, :active},
           {:active, :refresh_required},
           {:refresh_required, :refreshing},
           {:refreshing, :active},
           {:active, :degraded},
           {:refresh_required, :degraded},
           {:refreshing, :degraded},
           {:active, :expired},
           {:refresh_required, :expired},
           {:refreshing, :expired},
           {:degraded, :expired},
           {:active, :revoking},
           {:degraded, :revoking},
           {:expired, :revoking},
           {:revoking, :revoked},
           {:active, :disconnecting},
           {:degraded, :disconnecting},
           {:expired, :disconnecting},
           {:disconnecting, :disconnected}
         ])
  @statuses Map.new(@edges, fn {from, _to} -> {Atom.to_string(from), from} end)
  @doc "Returns whether a provider connection may move directly between two statuses."
  @spec allowed?(atom(), atom()) :: boolean()
  def allowed?(from, to), do: MapSet.member?(@edges, {from, to})

  @doc "Locks and version-fences the single authoritative connection state writer."
  def mutate(connection_id, expected_version, target, fun)
      when is_binary(connection_id) and is_integer(expected_version) and is_atom(target) and
             is_function(fun, 1) do
    import Ecto.Query
    alias EzagentCore.Repo
    alias Ezagent.ProviderConnection.Connection

    Repo.transaction(fn ->
      connection =
        Connection
        |> where([row], row.connection_id == ^connection_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      with %Connection{} = connection <- connection,
           true <- connection.connection_version == expected_version,
           {:ok, current} <- Map.fetch(@statuses, connection.status),
           true <- mutation_allowed?(current, target),
           {:ok, attrs} <- fun.(connection) do
        connection
        |> Ecto.Changeset.change(Map.put(attrs, :connection_version, expected_version + 1))
        |> Repo.update!()
      else
        nil -> Repo.rollback(:connection_not_found)
        # A terminal source (revoked/disconnected/failed) has no outgoing
        # edge, so Map.fetch fails with a bare :error — report the closed
        # code instead of crashing the transaction with WithClauseError.
        # (An edge-disallowed non-terminal mutation still reports
        # :stale_version; callers classify on it, so it is kept.)
        :error -> Repo.rollback(:connection_terminal)
        false -> Repo.rollback(:stale_version)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp mutation_allowed?(:refreshing, :refreshing), do: true
  defp mutation_allowed?(current, target), do: allowed?(current, target)
end
