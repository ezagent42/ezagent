Mix.install([
  {:ecto_libsql, "~> 0.9.1"}
])

db_path = System.get_env("LIBSQL_SPIKE_DB", "/private/tmp/cf-libsql-spike.db")
uri = System.get_env("LIBSQL_SPIKE_URI")
auth_token = System.get_env("LIBSQL_SPIKE_AUTH_TOKEN")
sync? = System.get_env("LIBSQL_SPIKE_SYNC", "false") in ["1", "true", "yes"]
reset? = System.get_env("LIBSQL_SPIKE_RESET", "false") in ["1", "true", "yes"]

if reset? do
  File.rm(db_path)
end

repo_opts =
  [
    adapter: Ecto.Adapters.LibSql,
    pool_size: 1
  ]
  |> Keyword.put(:database, db_path)
  |> then(fn opts ->
    if uri && uri != "" do
      opts
      |> Keyword.put(:uri, uri)
      |> Keyword.put(:sync, sync?)
    else
      opts
    end
  end)
  |> then(fn opts ->
    if auth_token && auth_token != "" do
      Keyword.put(opts, :auth_token, auth_token)
    else
      opts
    end
  end)

Application.put_env(:cf_storage_spike, CfStorageSpike.Repo, repo_opts)

defmodule CfStorageSpike.Repo do
  use Ecto.Repo,
    otp_app: :cf_storage_spike,
    adapter: Ecto.Adapters.LibSql
end

{:ok, repo_pid} = CfStorageSpike.Repo.start_link()

Ecto.Adapters.SQL.query!(
  CfStorageSpike.Repo,
  "CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL, inserted_at TEXT NOT NULL)",
  []
)

value = "spike-" <> Integer.to_string(System.system_time(:millisecond))

{:ok, _} =
  CfStorageSpike.Repo.transaction(fn ->
    Ecto.Adapters.SQL.query!(
      CfStorageSpike.Repo,
      """
      INSERT INTO kv (k, v, inserted_at)
      VALUES (?, ?, datetime('now'))
      ON CONFLICT(k) DO UPDATE SET v = excluded.v, inserted_at = excluded.inserted_at
      """,
      ["boot", value]
    )
  end)

Supervisor.stop(repo_pid)

{:ok, repo_pid} = CfStorageSpike.Repo.start_link()

%{rows: rows} =
  Ecto.Adapters.SQL.query!(
    CfStorageSpike.Repo,
    "SELECT k, v, inserted_at FROM kv WHERE k = ?",
    ["boot"]
  )

Supervisor.stop(repo_pid)

IO.puts("mode=#{if uri && uri != "", do: "embedded_or_remote", else: "local_file"}")
IO.puts("db_path=#{db_path}")
if uri && uri != "", do: IO.puts("uri=#{uri}")
IO.inspect(rows, label: "rows_after_repo_restart")

case rows do
  [["boot", ^value, _inserted_at]] -> :ok
  other -> raise "unexpected rows after restart: #{inspect(other)}"
end
