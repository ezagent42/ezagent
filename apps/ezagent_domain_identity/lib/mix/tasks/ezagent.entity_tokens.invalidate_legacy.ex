defmodule Mix.Tasks.Ezagent.EntityTokens.InvalidateLegacy do
  @shortdoc "Delete legacy entity-token rows that have no HMAC digest"
  @moduledoc """
  Hygiene step for the versioned-HMAC PAT rollout. New binaries already reject
  rows whose `token_digest` is NULL; this task deletes those unrecoverable
  bcrypt-era rows after the bootstrap admin has minted a new PAT.
  """

  use Mix.Task
  import Ecto.Query

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    {count, _} =
      from(t in Ezagent.Entity.Token, where: is_nil(t.token_digest))
      |> EzagentCore.Repo.delete_all()

    Mix.shell().info("Deleted #{count} legacy entity token row(s) without token_digest.")
  end
end
