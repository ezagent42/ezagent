defmodule EzagentPluginCc.BridgeAdapter do
  @moduledoc """
  AgentBridge adapter for Claude Code bridge sidecars.
  """

  @behaviour Ezagent.AgentBridge.Adapter

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

    if is_list(attachments) do
      :ok = dispatch_reply(socket.assigns.agent_uri, sessions, text, ref, attachments)
      {:reply, {:ok, %{}}, socket}
    else
      {:reply, {:error, %{reason: "attachments must be a list of maps"}}, socket}
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

  @doc false
  def dispatch_reply(agent_uri, sessions, text, ref, attachments) do
    ref_uri =
      case ref do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> Ezagent.URI.parse!(s)
      end

    body = %{text: text, attachments: normalize_attachments(attachments)}
    msg = Ezagent.Message.new(agent_uri, body, ref: ref_uri)

    for session_uri_str <- sessions do
      # SPEC 2026-05-27-uri-canonicalization §3.3 — `session_uri_str` is
      # client-supplied via the cc bridge WebSocket; canonicalize via
      # the chokepoint FIRST, then construct the action-bearing target
      # via `URI.to_string/1` of the canonical form. This is the §3.4
      # query-target idiom — input to URI.new!/1 is canonical-by-
      # construction. Malformed session URIs from the client get a
      # graceful skip (Invariant #9 — no silent crash from boundary
      # input).
      with {:ok, session_uri} <- safe_parse_session(session_uri_str) do
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
      end
    end

    :ok
  end

  defp safe_parse_session(s) when is_binary(s) do
    {:ok, Ezagent.URI.parse!(s)}
  rescue
    ArgumentError -> :error
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
end
