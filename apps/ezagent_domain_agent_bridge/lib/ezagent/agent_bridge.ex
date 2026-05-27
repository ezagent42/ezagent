defmodule Ezagent.AgentBridge do
  @moduledoc """
  Domain facade for delivering chat payloads to bridge-backed agents.
  """

  require Logger

  alias Ezagent.AgentBridge.{AdapterRegistry, Payload, Registry}

  @spec deliver(URI.t(), Payload.t()) :: :ok | {:error, term()}
  def deliver(%URI{} = agent_uri, %Payload{} = payload) do
    with {:ok, channel_pid} <- lookup_channel(agent_uri),
         {:ok, flavor} <- derive_flavor(agent_uri),
         :ok <- AdapterRegistry.deliver_or_buffer(flavor, payload, channel_pid) do
      :ok
    else
      {:error, reason} -> drop(agent_uri, payload, reason)
    end
  end

  defp lookup_channel(agent_uri) do
    case Registry.lookup(agent_uri) do
      {:ok, channel_pid} -> {:ok, channel_pid}
      :error -> {:error, :no_bridge}
    end
  end

  defp drop(agent_uri, payload, reason) do
    Logger.warning(
      "AgentBridge deliver dropped for #{URI.to_string(agent_uri)}: #{inspect(reason)}. " <>
        "Message from #{URI.to_string(payload.sender_uri)}: " <>
        String.slice(payload.text || "", 0, 80)
    )

    :telemetry.execute(
      [:ezagent, :agent_bridge, :deliver, :dropped],
      %{count: 1},
      %{
        recipient: agent_uri,
        sender: payload.sender_uri,
        event_type: payload.event_type,
        reason: reason
      }
    )

    {:error, reason}
  end

  defp derive_flavor(%URI{scheme: "entity", host: "agent", path: "/" <> rest})
       when rest != "" do
    with [_workspace, entity_name] when entity_name != "" <-
           String.split(rest, "/", parts: 2),
         [flavor, suffix] when flavor != "" and suffix != "" <-
           String.split(entity_name, "_", parts: 2) do
      {:ok, flavor}
    else
      _ -> {:error, :unknown_agent_flavor}
    end
  end

  defp derive_flavor(_), do: {:error, :unknown_agent_flavor}
end
