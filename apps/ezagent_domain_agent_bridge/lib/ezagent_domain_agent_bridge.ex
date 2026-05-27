defmodule EzagentDomainAgentBridge do
  @moduledoc """
  Domain application for bridge-backed agent sidecars.

  PR-B promotes the persistent connect-token store and the live
  `agent_uri -> channel_pid` registry out of `ezagent_plugin_cc`.
  PR-C promotes the Phoenix Socket and Channel entry points and wires
  the canonical `/agent_bridge` mount plus the legacy `/cc_socket`
  compatibility mount.
  PR-D adds the generic payload envelope, adapter behaviour, adapter
  registry, and `Ezagent.AgentBridge.deliver/2` facade.
  """
end
