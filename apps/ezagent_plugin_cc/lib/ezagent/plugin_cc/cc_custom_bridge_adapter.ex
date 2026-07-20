defmodule EzagentPluginCc.CcCustomBridgeAdapter do
  @moduledoc """
  AgentBridge adapter for the `"cc-custom"` flavor (PTY transport).

  The completion backend is a dimension ORTHOGONAL to transport: a cc-custom
  agent is the same claude Claude Code sidecar over the same `subprocess_ws`
  esr-bridge as plain `cc` — only the LLM endpoint differs (the catalog
  profile's env block, injected at launch). So this adapter is a thin delegate
  to `EzagentPluginCc.BridgeAdapter`; it exists only to give the distinct
  `"cc-custom"` flavor its required 1:1 adapter registration
  (`AdapterRegistry` rejects an adapter whose `flavor/0` ≠ the registered
  flavor) and its own channel-topic namespace.

  The cc-custom claude sidecar joins `agent_bridge:cc-custom:<uri>` (the
  channel validates the topic flavor against the agent's resolved flavor); the
  PTY launch env sets `EZAGENT_BRIDGE_TOPIC` to that topic
  (`SpawnPlan.build_claude_cmd/3`). Same `/agent_bridge` socket as `cc` — the
  generic `agent_bridge:<flavor>:<uri>` channel handles every flavor, so no
  new socket mount is needed.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  alias EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "cc-custom"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: BridgeAdapter.transport_class()

  @impl Ezagent.AgentBridge.Adapter
  defdelegate deliver(payload, channel_pid), to: BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate handle_client_event(event, params, socket), to: BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate socket_path, to: BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  def channel_topic_prefix, do: "agent_bridge:cc-custom:"

  @impl Ezagent.AgentBridge.Adapter
  defdelegate join_info(params, socket), to: BridgeAdapter
end
