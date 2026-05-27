defmodule EzagentPluginCc.TokenStore do
  @moduledoc """
  Deprecated cc-named shim for `Ezagent.AgentBridge.TokenStore`.

  The on-disk YAML path and token shape are unchanged:
  `$EZAGENT_HOME/<profile>/credentials/cc-channels.yaml`.
  """

  @doc deprecated: "Use Ezagent.AgentBridge.TokenStore.mint/1"
  def mint(agent_uri), do: Ezagent.AgentBridge.TokenStore.mint(agent_uri)

  @doc deprecated: "Use Ezagent.AgentBridge.TokenStore.lookup_by_token/1"
  def lookup_by_token(token), do: Ezagent.AgentBridge.TokenStore.lookup_by_token(token)

  @doc deprecated: "Use Ezagent.AgentBridge.TokenStore.list_all/0"
  def list_all, do: Ezagent.AgentBridge.TokenStore.list_all()
end
