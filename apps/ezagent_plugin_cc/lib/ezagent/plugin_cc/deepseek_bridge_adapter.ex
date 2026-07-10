defmodule EzagentPluginCc.DeepseekBridgeAdapter do
  @moduledoc """
  AgentBridge adapter for the `"cc-deepseek"` flavor (PTY transport).

  DeepSeek is a BACKEND dimension orthogonal to transport: a cc-deepseek agent
  is the same claude Claude Code sidecar over the same `subprocess_ws` esr-bridge
  as plain `cc` — only the LLM endpoint differs (env-injected). So this adapter
  is a thin delegate to `EzagentPluginCc.BridgeAdapter`; it exists only to give
  the distinct `"cc-deepseek"` flavor its required 1:1 adapter registration
  (`AdapterRegistry` rejects an adapter whose `flavor/0` ≠ the registered flavor)
  and its own channel-topic namespace.

  The deepseek claude sidecar joins `agent_bridge:cc-deepseek:<uri>` (the channel
  validates the topic flavor against the agent's resolved flavor); the PTY launch
  env sets `EZAGENT_BRIDGE_TOPIC` to that topic (`SpawnPlan.build_claude_cmd/3`).
  Same `/agent_bridge` socket as `cc` — the generic `agent_bridge:<flavor>:<uri>`
  channel handles every flavor, so no new socket mount is needed.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  alias EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "cc-deepseek"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: BridgeAdapter.transport_class()

  @impl Ezagent.AgentBridge.Adapter
  defdelegate deliver(payload, channel_pid), to: BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate handle_client_event(event, params, socket), to: BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate socket_path, to: BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  def channel_topic_prefix, do: "agent_bridge:cc-deepseek:"

  @impl Ezagent.AgentBridge.Adapter
  defdelegate join_info(params, socket), to: BridgeAdapter
end
