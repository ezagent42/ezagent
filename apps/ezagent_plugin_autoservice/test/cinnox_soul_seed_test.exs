defmodule EzagentPluginAutoservice.CinnoxSoulSeedTest do
  use EzagentCore.DataCase, async: false

  alias EzagentPluginAutoservice.CinnoxSoulSeed
  alias Ezagent.Socialware.ConfigStore

  test "seed_soul/2 writes a ConfigObject pointed at the bot's session-layer soul key" do
    ws = Ezagent.URI.workspace(:team_alpha)
    bot = Ezagent.URI.agent(:team_alpha, "cs-bot-#{System.unique_integer([:positive])}")

    {:ok, %{config_id: id}} = CinnoxSoulSeed.seed_soul(bot, ws)

    {:ok, obj} = ConfigStore.resolve("session", ws, bot, "soul")
    assert obj.id == id
    # The vendored cinnox soul is one authored markdown doc; it must land
    # verbatim under the soul_md key so ConfigProjection renders it as CLAUDE.md.
    assert obj.body["soul_md"] =~ "IDENTITY"
  end
end
