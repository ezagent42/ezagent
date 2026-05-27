defmodule EzagentPluginCc.BridgeAdapter do
  @moduledoc """
  AgentBridge adapter for Claude Code bridge sidecars.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  require Logger

  alias Ezagent.AgentBridge.Payload

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

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "cc"

  @impl Ezagent.AgentBridge.Adapter
  def agent_uri_prefix, do: "cc_"

  @impl Ezagent.AgentBridge.Adapter
  def deliver(%Payload{} = payload, channel_pid) when is_pid(channel_pid) do
    send(
      channel_pid,
      {:agent_bridge_push, "to_claude", %{"content" => payload.text, "meta" => payload.meta}}
    )

    :ok
  end

  @impl Ezagent.AgentBridge.Adapter
  def handle_client_event("reply", %{"text" => text, "session_uris" => sessions} = params, socket)
      when is_binary(text) and is_list(sessions) do
    ref = Map.get(params, "ref")
    attachments = Map.get(params, "attachments", [])

    cond do
      not is_list(attachments) ->
        {:reply, {:error, %{reason: "attachments must be a list of maps"}}, socket}

      # Invariant #9 closure r3 — codex caught that an empty `session_uris`
      # list silently succeeded (Enum.split_with returned {[], []}; no
      # Logger / telemetry / skipped surface). Treat zero-target as a
      # boundary error: claude gets a structured error, ops sees the
      # telemetry, and the malformed/zero case is never a silent ACK.
      sessions == [] ->
        Logger.warning(
          "EzagentPluginCc.BridgeAdapter: rejected cc bridge reply with empty " <>
            "session_uris (agent=#{URI.to_string(socket.assigns.agent_uri)})"
        )

        :telemetry.execute(
          [:ezagent, :plugin_cc, :bridge_adapter, :reply_rejected],
          %{count: 1},
          %{
            agent_uri: URI.to_string(socket.assigns.agent_uri),
            reason: :empty_session_uris
          }
        )

        {:reply, {:error, %{reason: "session_uris must be a non-empty list"}}, socket}

      true ->
        case dispatch_reply(socket.assigns.agent_uri, sessions, text, ref, attachments) do
          {:ok, %{dispatched: dispatched, skipped: []}} ->
            {:reply, {:ok, %{dispatched: dispatched}}, socket}

          {:ok, %{dispatched: dispatched, skipped: skipped}} ->
            # Invariant #9 — malformed session URIs from the client surface
            # back to the boundary so claude knows not all sessions
            # received the reply. Telemetry + Logger.warning also fires
            # inside dispatch_reply/5 for ops visibility.
            {:reply, {:ok, %{dispatched: dispatched, skipped: skipped}}, socket}
        end
    end
  end

  def handle_client_event("reply", _other, socket) do
    {:reply, {:error, %{reason: "reply requires text + session_uris"}}, socket}
  end

  def handle_client_event(_event, _params, socket), do: {:noreply, socket}

  @impl Ezagent.AgentBridge.Adapter
  def socket_path, do: "/agent_bridge"

  @impl Ezagent.AgentBridge.Adapter
  def channel_topic_prefix, do: "agent_bridge:cc:"

  @impl Ezagent.AgentBridge.Adapter
  def join_info(params, _socket) do
    %{
      claude_info: Map.get(params, "claude_info", %{}),
      tools: Map.get(params, "tools", [])
    }
  end

  @doc """
  Dispatch the bridge reply to every supplied session URI.

  Returns `{:ok, %{dispatched: [valid_uri_str], skipped: [bad_uri_str]}}`.
  Malformed URIs are skipped (Invariant #9 — graceful surface from a
  user-facing transport, not a silent process crash) AND logged at
  warning level AND emitted as telemetry so ops sees the drop. The
  caller (`handle_client_event/3`) propagates the `skipped` list back
  to the client so claude can decide whether to retry.
  """
  @spec dispatch_reply(URI.t(), [String.t()], String.t(), term(), [map()]) ::
          {:ok, %{dispatched: [String.t()], skipped: [String.t()]}}
  def dispatch_reply(agent_uri, sessions, text, ref, attachments) do
    ref_uri =
      case ref do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> Ezagent.URI.parse!(s)
      end

    body = %{text: text, attachments: normalize_attachments(attachments)}
    msg = Ezagent.Message.new(agent_uri, body, ref: ref_uri)

    {dispatched, skipped} =
      Enum.split_with(sessions, fn session_uri_str ->
        case safe_parse_session(session_uri_str) do
          {:ok, session_uri} ->
            # SPEC 2026-05-27-uri-canonicalization §3.3 + §3.4 —
            # session_uri_str came from the cc bridge WebSocket and was
            # canonicalized via the chokepoint above; URI.new!/1 here
            # consumes the canonical-by-construction string per the
            # §3.4 query-target idiom.
            target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

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

            true

          :error ->
            false
        end
      end)

    if skipped != [] do
      # Invariant #9 — malformed boundary input MUST surface via at
      # least one observable channel. We hit three: Logger (operator
      # tail), telemetry (metrics), and the channel ACK shape (claude
      # bridge sees the partial result).
      Logger.warning(
        "EzagentPluginCc.BridgeAdapter: dropped #{length(skipped)} malformed " <>
          "session URI(s) from cc bridge reply (agent=#{URI.to_string(agent_uri)}): " <>
          "#{inspect(skipped)}"
      )

      :telemetry.execute(
        [:ezagent, :plugin_cc, :bridge_adapter, :reply_skipped],
        %{count: length(skipped)},
        %{agent_uri: URI.to_string(agent_uri), skipped: skipped}
      )
    end

    {:ok, %{dispatched: dispatched, skipped: skipped}}
  end

  defp safe_parse_session(s) when is_binary(s) do
    {:ok, Ezagent.URI.parse!(s)}
  rescue
    ArgumentError -> :error
  end

  defp safe_parse_session(_), do: :error

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
end
