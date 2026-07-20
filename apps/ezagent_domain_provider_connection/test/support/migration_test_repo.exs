defmodule Ezagent.ProviderConnection.MigrationTestRepo do
  use Ecto.Repo,
    otp_app: :ezagent_domain_provider_connection,
    adapter: Ecto.Adapters.Postgres
end
