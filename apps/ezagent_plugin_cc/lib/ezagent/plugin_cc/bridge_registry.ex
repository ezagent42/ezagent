defmodule EzagentPluginCc.BridgeRegistry do
  @moduledoc """
  Deprecated cc-named shim for `Ezagent.AgentBridge.Registry`.

  The implementation moved to the AgentBridge domain in PR-B of the
  codex plugin sequence. This module preserves the existing cc plugin
  API surface for the `/cc_socket` deprecation window.
  """

  @doc deprecated: "Use Ezagent.AgentBridge.Registry.init/0"
  def init, do: Ezagent.AgentBridge.Registry.init()

  @doc deprecated:
         "Use Ezagent.AgentBridge.Registry.legacy_topic/0 for the cc compatibility topic or topic/0 for the generic topic"
  def topic, do: Ezagent.AgentBridge.Registry.legacy_topic()

  @doc deprecated: "Use Ezagent.AgentBridge.Registry.bind/3"
  def bind(agent_uri, channel_pid, info \\ %{}),
    do: Ezagent.AgentBridge.Registry.bind(agent_uri, channel_pid, info)

  @doc deprecated: "Use Ezagent.AgentBridge.Registry.unbind/1"
  def unbind(agent_uri), do: Ezagent.AgentBridge.Registry.unbind(agent_uri)

  @doc deprecated: "Use Ezagent.AgentBridge.Registry.lookup/1"
  def lookup(agent_uri), do: Ezagent.AgentBridge.Registry.lookup(agent_uri)

  @doc deprecated: "Use Ezagent.AgentBridge.Registry.list_all/0"
  def list_all, do: Ezagent.AgentBridge.Registry.list_all()

  @doc deprecated: "Use Ezagent.AgentBridge.Registry.list_connected/0"
  def list_connected, do: Ezagent.AgentBridge.Registry.list_connected()

  @doc deprecated: "Use Ezagent.AgentBridge.Registry.count/0"
  def count, do: Ezagent.AgentBridge.Registry.count()

  @doc deprecated: "Use Ezagent.AgentBridge.Registry.status/0"
  def status, do: Ezagent.AgentBridge.Registry.status()
end
