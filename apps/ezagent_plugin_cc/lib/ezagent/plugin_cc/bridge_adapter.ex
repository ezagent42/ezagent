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
    send(channel_pid, {:to_claude, %{"content" => payload.text, "meta" => payload.meta}})
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

  @doc false
  def dispatch_reply(agent_uri, sessions, text, ref, attachments) do
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

    :ok
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
