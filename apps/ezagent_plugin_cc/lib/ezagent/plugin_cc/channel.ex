defmodule EzagentPluginCc.Channel do
  @moduledoc """
  Deprecated cc-named shim for `Ezagent.AgentBridge.Channel`.
  """
  use Phoenix.Channel

  @impl true
  def join(topic, params, socket), do: Ezagent.AgentBridge.Channel.join(topic, params, socket)

  @impl true
  def handle_in(event, params, socket),
    do: Ezagent.AgentBridge.Channel.handle_in(event, params, socket)

  @impl true
  def handle_info(message, socket), do: Ezagent.AgentBridge.Channel.handle_info(message, socket)

  @impl true
  def terminate(reason, socket), do: Ezagent.AgentBridge.Channel.terminate(reason, socket)
end
