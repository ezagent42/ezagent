defmodule EzagentPluginCodex.CodexRemoteBridgeAdapter do
  @moduledoc """
  BridgeAdapter for `"codex-remote"` flavor — delegates to the `"codex"`
  BridgeAdapter but declares flavor `"codex-remote"`.
  """
  @behaviour Ezagent.AgentBridge.Adapter

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "codex-remote"

  @impl Ezagent.AgentBridge.Adapter
  defdelegate transport_class, to: EzagentPluginCodex.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate deliver(payload, channel_pid), to: EzagentPluginCodex.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate handle_client_event(event, params, socket), to: EzagentPluginCodex.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate socket_path, to: EzagentPluginCodex.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  def channel_topic_prefix, do: "agent_bridge:codex-remote:"

  @impl Ezagent.AgentBridge.Adapter
  defdelegate join_info(params, socket), to: EzagentPluginCodex.BridgeAdapter
end
