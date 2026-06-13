defmodule EzagentCore.Repo do
  @moduledoc """
  The Ecto repository for ezagent, backed by SQLite (`Ecto.Adapters.SQLite3`).

  SQLite is the deliberate single-node store: ezagent runs as one BEAM per
  deployment, so an embedded file DB avoids operating a separate database
  service. This repo owns the SQLite-backed application TABLES (kind snapshots,
  identity rows, socialware settlements, …). It is NOT the whole durable
  boundary: filesystem state under `EZAGENT_HOME` (credentials, agent config,
  logs) lives outside the repo — backup/restore/migration must cover both.
  """
  use Ecto.Repo,
    otp_app: :ezagent_core,
    adapter: Ecto.Adapters.SQLite3
end
