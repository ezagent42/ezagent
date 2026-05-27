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

  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  @attachment_key_atoms %{
    "type" => :type,
    "local_path" => :local_path,
    "name" => :name
  }
  @attachment_type_atoms %{
    "image" => :image,
    "file" => :file,
    "audio" => :audio,
    "video" => :video,
    "media" => :media
  }

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
  def handle_in("reply", %{"text" => text, "session_uris" => sessions} = params, socket)
      when is_binary(text) and is_list(sessions) do
    ref = Map.get(params, "ref")
    attachments = Map.get(params, "attachments", [])

    cond do
      not is_list(attachments) ->
        {:reply, {:error, %{reason: "attachments must be a list of maps"}}, socket}

      true ->
        send(self(), {:dispatch_reply, sessions, text, ref, attachments})
        {:reply, :ok, socket}
    end
  end

  def handle_in("reply", _other, socket) do
    {:reply, {:error, %{reason: "reply requires text + session_uris"}}, socket}
  end

  def handle_in(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:to_claude, payload}, socket) do
    push(socket, "to_claude", payload)
    {:noreply, socket}
  end

  def handle_info({:dispatch_reply, sessions, text, ref, attachments}, socket) do
    agent_uri = socket.assigns.agent_uri

    ref_uri =
      case ref do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> URI.new!(s)
      end

    body = %{text: text, attachments: normalize_attachments(attachments)}
    msg = Ezagent.Message.new(agent_uri, body, ref: ref_uri)

    for session_uri_str <- sessions do
      target = URI.new!("#{session_uri_str}?action=chat.send")

      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: agent_uri,
          caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
          reply: :ignore
        }
      })
    end

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
    info = %{
      bridge_flavor: flavor,
      claude_info: Map.get(params, "claude_info", %{}),
      tools: Map.get(params, "tools", []),
      remote_ip: format_remote_ip(socket)
    }

    case BridgeRegistry.bind(socket.assigns.agent_uri, self(), info) do
      :ok ->
        :ok = ensure_agent_kind(socket.assigns.agent_uri)
        {:ok, socket}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
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

  defp normalize_attachments(list) when is_list(list) do
    Enum.map(list, fn
      %{} = m -> normalize_attachment_keys(m)
      other -> other
    end)
  end

  defp normalize_attachment_keys(m) do
    Enum.into(m, %{}, fn
      {k, v} when is_binary(k) ->
        {Map.get(@attachment_key_atoms, k, k), normalize_attachment_value(k, v)}

      {k, v} ->
        {k, v}
    end)
  end

  defp normalize_attachment_value("type", v) when is_binary(v),
    do: Map.get(@attachment_type_atoms, v, v)

  defp normalize_attachment_value(_, v), do: v

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
