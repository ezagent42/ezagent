defmodule EzagentPluginCc.CcHeadlessCustomBridgeAdapter do
  @moduledoc """
  AgentBridge adapter for the `"cc-headless-custom"` flavor.

  Headless is an `:in_process_sync` transport (Agent receive → this adapter →
  the supervised Python SDK sidecar → re-dispatch of the result). The custom
  backend only changes the sidecar's env (the catalog profile's block), not
  this control flow, so this adapter is a thin delegate to
  `EzagentPluginCc.CcHeadlessBridgeAdapter`; it exists only to give the
  distinct `"cc-headless-custom"` flavor its required 1:1 adapter registration
  (`AdapterRegistry` rejects an adapter whose `flavor/0` ≠ the registered
  flavor) and its own channel-topic prefix.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  alias EzagentPluginCc.CcHeadlessBridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "cc-headless-custom"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: CcHeadlessBridgeAdapter.transport_class()

  @impl Ezagent.AgentBridge.Adapter
  defdelegate deliver(payload, channel_pid), to: CcHeadlessBridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate handle_client_event(event, params, socket), to: CcHeadlessBridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate socket_path, to: CcHeadlessBridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  def channel_topic_prefix, do: "cc-headless-custom"

  @impl Ezagent.AgentBridge.Adapter
  defdelegate join_info(params, socket), to: CcHeadlessBridgeAdapter
end
