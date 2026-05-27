defmodule Ezagent.AgentBridge.Adapter do
  @moduledoc """
  Per-flavor adapter for AgentBridge delivery.

  The domain bridge owns registry lookup and dispatch; each plugin
  adapter translates the generic payload into its sidecar protocol.
  """

  @callback flavor() :: String.t()
  @callback agent_uri_prefix() :: String.t()
  @callback deliver(Ezagent.AgentBridge.Payload.t(), pid()) :: :ok | {:error, term()}

  @callback handle_client_event(String.t(), map(), Phoenix.Socket.t()) ::
              {:reply, {:ok | :error, map()}, Phoenix.Socket.t()}
              | {:noreply, Phoenix.Socket.t()}

  @callback socket_path() :: String.t()
  @callback channel_topic_prefix() :: String.t()

  @optional_callbacks socket_path: 0, channel_topic_prefix: 0
end
