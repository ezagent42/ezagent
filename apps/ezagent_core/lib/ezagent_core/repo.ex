defmodule EzagentCore.Repo do
  @moduledoc """
  The Ecto repository for ezagent, backed by SQLite (`Ecto.Adapters.SQLite3`).

  SQLite is the deliberate single-node store: ezagent runs as one BEAM per
  deployment, so an embedded file DB avoids operating a separate database
  service. All durable state (kind snapshots, identity, socialware settlements,
  …) goes through this repo.
  """
  use Ecto.Repo,
    otp_app: :ezagent_core,
    adapter: Ecto.Adapters.SQLite3
end
