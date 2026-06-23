defmodule EzagentPluginCc.CcHeadlessBridgeAdapter do
  @moduledoc """
  BridgeAdapter for `"cc-headless"` flavor — delegates to the `"cc"`
  BridgeAdapter but declares flavor `"cc-headless"`.
  """
  @behaviour Ezagent.AgentBridge.Adapter

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "cc-headless"

  @impl Ezagent.AgentBridge.Adapter
  defdelegate transport_class, to: EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate deliver(payload, channel_pid), to: EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate handle_client_event(event, params, socket), to: EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate socket_path, to: EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate channel_topic_prefix, to: EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate join_info(params, socket), to: EzagentPluginCc.BridgeAdapter
end
