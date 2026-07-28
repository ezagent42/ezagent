defmodule Ezagent.CredentialIncarnationBackfillMigrationTestRepo do
  use Ecto.Repo,
    otp_app: :ezagent_core,
    adapter: Ecto.Adapters.Postgres
end
