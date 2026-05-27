defmodule EzagentDomainAgentBridge do
  @moduledoc """
  Domain application for bridge-backed agent sidecars.

  PR-B promotes the persistent connect-token store and the live
  `agent_uri -> channel_pid` registry out of `ezagent_plugin_cc`.
  Socket, Channel, payload, and adapter delivery are introduced by the
  following PRs in the AgentBridge sequence.
  """
end
