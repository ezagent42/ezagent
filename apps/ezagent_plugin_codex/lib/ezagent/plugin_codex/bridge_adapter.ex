defmodule EzagentPluginCodex.BridgeAdapter do
  @moduledoc """
  AgentBridge adapter for Codex app-server bridge sidecars.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  alias Ezagent.AgentBridge.AttachmentNormalizer
  alias Ezagent.AgentBridge.Payload

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "codex"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: :subprocess_ws

  @impl Ezagent.AgentBridge.Adapter
  def deliver(%Payload{} = payload, channel_pid) when is_pid(channel_pid) do
    message = %{
      "content" => payload.text,
      "meta" => payload.meta,
      "message_id" => payload.message_id,
      "session_uri" => uri_string(payload.session_uri),
      "sender_uri" => uri_string(payload.sender_uri),
      "event_type" => Atom.to_string(payload.event_type)
    }

    send(channel_pid, {:agent_bridge_push, "codex_turn", message})
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
  def channel_topic_prefix, do: "agent_bridge:codex:"

  @impl Ezagent.AgentBridge.Adapter
  def join_info(params, _socket) do
    %{
      codex_info: Map.get(params, "codex_info", %{}),
      tools: Map.get(params, "tools", ["reply"])
    }
  end

  @doc false
  def dispatch_reply(agent_uri, sessions, text, ref, attachments) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — every boundary input
    # routed through the canonical chokepoint. Mirrors the parity treatment
    # already applied to `EzagentPluginCc.BridgeAdapter` (cc and codex
    # bridges share a contract: client supplies raw strings, plugin
    # canonicalizes at the boundary).
    #
    # `ref` is the opaque 16-hex message id from the codex bridge sidecar
    # (per SPEC v2 §5.13 — message ids are plain UUIDs, NOT URIs). It
    # threads through as `:ref_id` (string) on `Message.new/3`; the
    # `:ref` keyword used by the pre-#438 code was silently dropped
    # (not a valid opt on `Message.new/3`).
    ref_id =
      case ref do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> s
      end

    body = %{text: text, attachments: AttachmentNormalizer.normalize_attachments(attachments)}
    msg = Ezagent.Message.new(agent_uri, body, ref_id: ref_id)

    for session_uri_str <- sessions do
      session_uri = Ezagent.URI.new!(session_uri_str)

      # SPEC §3.4 query-target idiom — `session_uri` is canonical-by-construction
      # via the chokepoint above; URI.new!/1 here consumes the canonical-form
      # string the carve-out permits.
      target = Ezagent.URI.with_action(session_uri, :chat, :send)

      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: agent_uri,
          caps: "chat-reply" |> Ezagent.SystemPrincipal.uri() |> Ezagent.SystemPrincipal.caps(),
          reply: :ignore
        }
      })
    end

    :ok
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(nil), do: nil
end
