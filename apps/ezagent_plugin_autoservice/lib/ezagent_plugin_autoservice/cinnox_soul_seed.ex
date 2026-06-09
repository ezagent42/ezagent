defmodule EzagentPluginAutoservice.CinnoxSoulSeed do
  @moduledoc """
  Seed the vendored cinnox customer soul as an immutable socialware
  `ConfigObject`, pointed at the bot agent's **session-layer `soul` key**, so
  `Ezagent.Socialware.ConfigProjection` renders it verbatim as the bot's
  `CLAUDE.md` (via the #17 user-cascade layer the provisioner repoints).

  autoservice → socialware migration, Stage 1 / DD3.
  """
  alias Ezagent.Socialware.ConfigStore
  alias EzagentPluginAutoservice.CinnoxAssets

  @soul_key "soul"

  @doc """
  Write the cinnox `customer_soul.md` as a `ConfigObject` + session-layer
  pointer for `bot_uri` in `workspace_uri`. Returns the `ConfigStore`
  write result (`{:ok, %{config_id: ..., object: ..., pointer: ...}}`).
  """
  @spec seed_soul(URI.t() | String.t(), URI.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def seed_soul(bot_uri, workspace_uri, opts \\ []) do
    actor_uri = Keyword.get(opts, :actor_uri, Ezagent.Entity.User.admin_uri())
    soul_md = File.read!(CinnoxAssets.soul_path())

    ConfigStore.write_and_point(%{
      layer: "session",
      workspace_uri: workspace_uri,
      subject_uri: bot_uri,
      key: @soul_key,
      body: %{"soul_md" => soul_md},
      actor_uri: actor_uri,
      source_turn_id: "cinnox-soul-seed"
    })
  end
end
