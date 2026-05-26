defmodule EzagentCore.Repo.Migrations.Phase6UserCliToken do
  use Ecto.Migration

  def change do
    # Phase 6 PR 7: per-user bearer token for `mix ezagent` CLI auth.
    #
    # Without this, CLI uses admin caps unconditionally (distributed
    # Erlang cookie is single-tenant). With a token, the running BEAM
    # resolves token → user URI → user's caps, so non-admin CLI
    # callers go through CapBAC.
    #
    # `cli_token` is null until the operator runs
    # `mix ezagent.user.token <uri> --rotate`. Unique-not-null partial-
    # index would be cleanest but SQLite's UNIQUE handles NULL as
    # always-distinct, which gives us the same effect without partial
    # index syntax.
    alter table(:users) do
      add :cli_token, :string
    end

    create unique_index(:users, [:cli_token], name: :users_cli_token_index)
  end
end
