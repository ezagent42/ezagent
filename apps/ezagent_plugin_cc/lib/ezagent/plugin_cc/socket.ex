defmodule EzagentPluginCc.Socket do
  @moduledoc """
  Deprecated cc-named shim for `Ezagent.AgentBridge.Socket`.

  PR-C promotes the Socket to the AgentBridge domain. This module keeps
  the legacy module name available for tests and external callers during
  the `/cc_socket` deprecation window.
  """
  use Phoenix.Socket

  channel "agent_bridge:*", Ezagent.AgentBridge.Channel
  channel "cc:bridge:*", Ezagent.AgentBridge.Channel

  @impl true
  def connect(params, socket, connect_info),
    do: Ezagent.AgentBridge.Socket.connect(params, socket, connect_info)

  @impl true
  def id(socket), do: Ezagent.AgentBridge.Socket.id(socket)
end
