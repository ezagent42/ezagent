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
         :ok <- verify_topic_flavor(flavor, socket.assigns.agent_uri),
         :ok <- verify_transport_class(flavor) do
      join_bridge(flavor, params, socket)
    else
      :transport_class_mismatch -> {:error, %{reason: "transport_class_mismatch"}}
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
      false -> {:error, %{reason: "topic_uri_mismatch"}}
      _ -> {:error, %{reason: "invalid_topic"}}
    end
  end

  def join("cc:bridge:" <> uri_str, params, socket) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # at inbound channel-join boundary; try/rescue preserves the
    # `:error` failure path for malformed topic URIs.
    with {:ok, topic_uri} <- safe_parse_uri(uri_str),
         :ok <- verify_topic_uri(topic_uri, socket),
         :ok <- verify_topic_flavor("cc", socket.assigns.agent_uri),
         :ok <- verify_transport_class("cc") do
      join_bridge("cc", params, socket)
    else
      :transport_class_mismatch -> {:error, %{reason: "transport_class_mismatch"}}
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
    # Pid-guarded: only remove OUR OWN binding. A stale/sibling channel for the
    # same agent URI terminating must not delete a newer live channel's row
    # (the cc-agent-not-deliverable race — see Registry.unbind/2).
    BridgeRegistry.unbind(socket.assigns.agent_uri, self())
    :ok
  end

  defp parse_agent_bridge_topic(rest) do
    case String.split(rest, ":", parts: 2) do
      [flavor, uri_str] when flavor != "" and uri_str != "" ->
        case safe_parse_uri(uri_str) do
          {:ok, %URI{} = uri} -> {:ok, flavor, uri}
          :error -> {:error, {:invalid_topic_uri, uri_str}}
        end

      _ ->
        {:error, :invalid_agent_bridge_topic}
    end
  end

  defp safe_parse_uri(s) when is_binary(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> :error
  end

  defp verify_topic_uri(%URI{} = topic_uri, socket) do
    if URI.to_string(topic_uri) == URI.to_string(socket.assigns.agent_uri) do
      :ok
    else
      false
    end
  end

  # A WS Channel join is only valid for a `:subprocess_ws` flavor. An
  # `:in_process_sync` flavor (e.g. a future curl agent) has no WebSocket
  # endpoint, so it must NEVER reach the Channel — reject the join (codex
  # MED-2 point 1). Unregistered flavors default to `:subprocess_ws`
  # (their adapter registers UP at boot and may not be present yet).
  defp verify_transport_class(flavor) when is_binary(flavor) do
    case AdapterRegistry.transport_class(flavor) do
      :subprocess_ws -> :ok
      _other -> :transport_class_mismatch
    end
  end

  defp verify_topic_flavor(topic_flavor, %URI{} = agent_uri) do
    case resolve_flavor(agent_uri) do
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
    # `join_info/2` is an `@optional_callbacks` on `Ezagent.AgentBridge.Adapter`;
    # `function_exported?/3` is NOT guard-allowed in Elixir 1.19 (CompileError
    # since 1.18+), so the check is hoisted into the case body. `Code.ensure_loaded?`
    # forces module load before introspection — adapter modules from other apps
    # may not be auto-loaded at the boundary.
    with {:ok, adapter} <- AdapterRegistry.lookup(flavor),
         true <- Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :join_info, 2),
         info when is_map(info) <- adapter.join_info(params, socket) do
      info
    else
      _ -> %{}
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

  defp resolve_flavor(%URI{} = agent_uri) do
    # A bridge joins while its agent may still be activating. Do not resolve
    # flavor by synchronously reading that live Kind: activation can be waiting
    # for this very join, which creates a timeout cycle. The sandbox's persisted
    # respawn flavor is available through the durable Kind read surface during
    # cold start; UriQuery remains the fallback for agents without that durable
    # field.
    case durable_respawn_flavor(agent_uri) do
      {:ok, flavor} -> flavor
      :none -> resolve_flavor_via_uri_query(agent_uri)
    end
  end

  defp durable_respawn_flavor(%URI{} = agent_uri) do
    with {:ok, sandbox, _meta} <- Ezagent.Kind.read_durable(agent_uri, :sandbox),
         respawn_data when is_map(respawn_data) <- Map.get(sandbox, :respawn_template_data),
         flavor when is_binary(flavor) and flavor != "" <-
           Map.get(respawn_data, :flavor) || Map.get(respawn_data, "flavor") do
      {:ok, flavor}
    else
      _ -> :none
    end
  end

  defp resolve_flavor_via_uri_query(%URI{} = agent_uri) do
    case Ezagent.UriQuery.resolve(:flavor, agent_uri) do
      {:ok, flavor} when is_binary(flavor) and flavor != "" -> flavor
      :none -> nil
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, {:invalid_agent_flavor, other}}
    end
  end
end
