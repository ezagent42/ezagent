defmodule EzagentPluginCc.Channel do
  @moduledoc """
  Phoenix.Channel hosting one CC bridge session.

  Topic shape: `cc:bridge:<agent_uri>` — agent_uri must match the
  Socket-level token auth (`socket.assigns.agent_uri`). Join asserts
  the topic matches.

  ## Lifecycle

  - `join/3` —
      1. binds socket pid as the bridge for `agent_uri` via
         `Ezagent.AgentBridge.Registry.bind/3` (capturing the
         claude/tools/remote-ip info the Python bridge passed in join
         params, so admin LV's connected-bridges table has something
         to render);
      2. ensures the `Ezagent.Entity.Agent` Kind for `agent_uri` exists by
         dispatching to `Ezagent.SpawnRegistry.spawn/1`. Mirrors what the
         v1 announce controller did — without this step, inbound
         dispatches against `entity://agent/...` URIs have no Kind pid to
         receive on and silently drop.

  - `handle_in("reply", %{...})` — Python bridge POSTs Claude's `reply`
    tool call. Accepts `text`, `session_uris`, optional `ref`, and
    **optional `attachments`** (`[{type, local_path, name}]`). Dispatches
    `chat/send` against each target session URI.

  - `terminate/2` — unbind on socket close.

  ## Why a separate Channel module (not in Socket)

  Socket = auth + per-connection assigns. Channel = topic-scoped
  message routing. The split lets multiple bridges share the same
  Socket process while each owns its own Channel pid.

  ## Push direction (BEAM → bridge)

  External callers (chat plugin's Agent receive handler) reach the
  bridge by sending `{:to_claude, payload}` to the bound Channel pid.
  The Channel forwards via `push(socket, "to_claude", payload)` so the
  WS client gets a real Phoenix.Channel event.
  """
  use Phoenix.Channel

  require Logger

  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  @impl true
  def join("cc:bridge:" <> _topic_uri, params, socket) do
    info = %{
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
        # SPEC caps-cleanup-v1 §4.4 — CC agent reply runs under
        # `system://chat-reply` (closed Catalog).
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

  # Mirrors the v1 announce controller's start_agent_kind path so that
  # inbound dispatches (Feishu → chat router → Agent.invoke(:receive))
  # have a live Kind pid to receive on. Idempotent — repeats on every
  # join, falls through cleanly if the Kind is already registered.
  defp ensure_agent_kind(%URI{} = agent_uri) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} ->
        :ok

      {:error, {:no_spawn_fn, scheme}} ->
        # The entity:// spawn fn is registered by ezagent_domain_chat at
        # boot. If it's missing, the chat plugin failed to start — log
        # but don't fail the bridge join (the inbound path would also
        # be broken; surfacing :ok at least lets reply traffic flow).
        Logger.warning(
          "EzagentPluginCc.Channel: no spawn_fn for scheme #{scheme}; " <>
            "Agent Kind for #{URI.to_string(agent_uri)} not ensured"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "EzagentPluginCc.Channel: failed to ensure Agent Kind for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Mirror chat.ex normalize_attachments/1 surface so the Channel can
  # accept raw maps from the Python bridge (`{"type": "image",
  # "local_path": "/abs", "name": "x"}`) without depending on chat's
  # private helper.
  defp normalize_attachments(list) when is_list(list) do
    Enum.map(list, fn
      %{} = m -> normalize_attachment_keys(m)
      other -> other
    end)
  end

  defp normalize_attachment_keys(m) do
    Enum.into(m, %{}, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), normalize_attachment_value(k, v)}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_attachment_value("type", v) when is_binary(v), do: String.to_atom(v)
  defp normalize_attachment_value(_, v), do: v

  defp format_remote_ip(socket) do
    case socket.assigns[:remote_ip] do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      other when not is_nil(other) -> inspect(other)
      nil -> "unknown"
    end
  end
end
