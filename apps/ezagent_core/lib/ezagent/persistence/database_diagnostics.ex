defmodule Ezagent.Persistence.DatabaseDiagnostics do
  @moduledoc """
  Database diagnostics for operator-only measurement tasks.

  This module is the reviewed boundary for adapter-specific diagnostic SQL.
  """

  @spec summary(module()) :: String.t()
  def summary(repo \\ EzagentCore.Repo) do
    pool = repo.config()[:pool_size]

    isolation = scalar(repo, "SHOW transaction_isolation")
    max_connections = scalar(repo, "SHOW max_connections")

    "adapter=postgres transaction_isolation=#{isolation} max_connections=#{max_connections} pool_size=#{pool}"
  rescue
    e -> "unavailable (#{inspect(e)})"
  end

  defp scalar(repo, sql) do
    case repo.query(sql, []) do
      {:ok, %{rows: [[value]]}} -> value
      _ -> "?"
    end
  end
end
