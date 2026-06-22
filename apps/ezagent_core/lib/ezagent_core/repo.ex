defmodule EzagentCore.Repo do
  @moduledoc """
  The Ecto repository for ezagent, backed by PostgreSQL.

  This repo owns the application tables (kind snapshots, identity rows,
  socialware settlements, ...). It is NOT the whole durable boundary:
  filesystem state under `EZAGENT_HOME` (credentials, agent config, logs)
  lives outside the repo, so backup/restore must cover both PostgreSQL and
  the profile directory.
  """
  use Ecto.Repo,
    otp_app: :ezagent_core,
    adapter: Ecto.Adapters.Postgres
end
