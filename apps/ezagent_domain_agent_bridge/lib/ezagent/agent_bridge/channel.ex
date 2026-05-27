defmodule Ezagent.AgentBridge.Channel do
  @moduledoc """
  Phoenix.Channel hosting one bridge-backed agent sidecar.

  Supported topics:

    * `agent_bridge:<flavor>:<agent_uri>` — canonical AgentBridge topic
    * `cc:bridge:<agent_uri>` — legacy cc alias for the deprecation window

  Join validates the topic URI against the token-authenticated
  `socket.assigns.agent_uri` from `Ezagent.AgentBridge.Socket.connect/3`.
  """
  use Phoenix.Channel

  require Logger

  alias Ezagent.AgentBridge.AdapterRegistry
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  @impl true
  def join("agent_bridge:" <> rest, params, socket) do
    with {:ok, flavor, topic_uri} <- parse_agent_bridge_topic(rest),
         :ok <- verify_topic_uri(topic_uri, socket),
         :ok <- verify_topic_flavor(flavor, socket.assigns.agent_uri) do
      join_bridge(flavor, params, socket)
    else
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
      false -> {:error, %{reason: "topic_uri_mismatch"}}
      _ -> {:error, %{reason: "invalid_topic"}}
    end
  end

  def join("cc:bridge:" <> uri_str, params, socket) do
    with {:ok, topic_uri} <- URI.new(uri_str),
         :ok <- verify_topic_uri(topic_uri, socket),
         :ok <- verify_topic_flavor("cc", socket.assigns.agent_uri) do
      join_bridge("cc", params, socket)
    else
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
      false -> {:error, %{reason: "topic_uri_mismatch"}}
      _ -> {:error, %{reason: "invalid_topic"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in(event, params, socket) when is_binary(event) and is_map(params) do
    case AdapterRegistry.lookup(socket.assigns.bridge_flavor) do
      {:ok, adapter} ->
        adapter.handle_client_event(event, params, socket)

      :error ->
        {:reply, {:error, %{reason: "bridge adapter not registered"}}, socket}
    end
  end

  @impl true
  def handle_info({:agent_bridge_push, event, payload}, socket) when is_binary(event) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    BridgeRegistry.unbind(socket.assigns.agent_uri)
    :ok
  end

  defp parse_agent_bridge_topic(rest) do
    case String.split(rest, ":", parts: 2) do
      [flavor, uri_str] when flavor != "" and uri_str != "" ->
        case URI.new(uri_str) do
          {:ok, %URI{} = uri} -> {:ok, flavor, uri}
          {:error, reason} -> {:error, {:invalid_topic_uri, reason}}
        end

      _ ->
        {:error, :invalid_agent_bridge_topic}
    end
  end

  defp verify_topic_uri(%URI{} = topic_uri, socket) do
    if URI.to_string(topic_uri) == URI.to_string(socket.assigns.agent_uri) do
      :ok
    else
      false
    end
  end

  defp verify_topic_flavor(topic_flavor, %URI{} = agent_uri) do
    case derive_flavor(agent_uri) do
      ^topic_flavor -> :ok
      other -> {:error, {:topic_flavor_mismatch, topic_flavor, other}}
    end
  end

  defp join_bridge(flavor, params, socket) do
    info =
      Map.merge(
        %{
          bridge_flavor: flavor,
          remote_ip: format_remote_ip(socket)
        },
        adapter_join_info(flavor, params, socket)
      )

    case BridgeRegistry.bind(socket.assigns.agent_uri, self(), info) do
      :ok ->
        :ok = ensure_agent_kind(socket.assigns.agent_uri)
        {:ok, Phoenix.Socket.assign(socket, :bridge_flavor, flavor)}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  defp adapter_join_info(flavor, params, socket) do
    case AdapterRegistry.lookup(flavor) do
      {:ok, adapter} when function_exported?(adapter, :join_info, 2) ->
        case adapter.join_info(params, socket) do
          info when is_map(info) -> info
          _other -> %{}
        end

      _ ->
        %{}
    end
  end

  defp ensure_agent_kind(%URI{} = agent_uri) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} ->
        :ok

      {:error, {:no_spawn_fn, scheme}} ->
        Logger.warning(
          "Ezagent.AgentBridge.Channel: no spawn_fn for scheme #{scheme}; " <>
            "Agent Kind for #{URI.to_string(agent_uri)} not ensured"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Ezagent.AgentBridge.Channel: failed to ensure Agent Kind for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_remote_ip(socket) do
    case socket.assigns[:remote_ip] do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      other when not is_nil(other) -> inspect(other)
      nil -> "unknown"
    end
  end

  defp derive_flavor(%URI{scheme: "entity", host: "agent", path: "/" <> rest})
       when rest != "" do
    with [_workspace, entity_name] when entity_name != "" <-
           String.split(rest, "/", parts: 2),
         [flavor, suffix] when flavor != "" and suffix != "" <-
           String.split(entity_name, "_", parts: 2) do
      flavor
    else
      _ -> nil
    end
  end

  defp derive_flavor(_), do: nil
end
