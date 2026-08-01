defmodule EzagentPluginCc.BridgeAdapter do
  @moduledoc """
  AgentBridge adapter for Claude Code bridge sidecars.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  require Logger

  alias Ezagent.AgentBridge.AttachmentNormalizer
  alias Ezagent.AgentBridge.Payload

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "cc"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: :subprocess_ws

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
        # Invariant #9 — the three-bucket result (dispatched / failed /
        # skipped) is propagated back to the client UNCONDITIONALLY so
        # claude (the cc bridge sidecar) sees per-URI outcome. Empty
        # failed/skipped lists are omitted to keep the ACK compact in
        # the happy path. Logger.warning + telemetry fire from
        # dispatch_reply/5 for ops visibility.
        {:ok, %{dispatched: dispatched, failed: failed, skipped: skipped}} =
          dispatch_reply(socket.assigns.agent_uri, sessions, text, ref, attachments)

        ack =
          %{dispatched: dispatched}
          |> maybe_put(:failed, failed)
          |> maybe_put(:skipped, skipped)

        {:reply, {:ok, ack}, socket}
    end
  end

  def handle_client_event("reply", _other, socket) do
    {:reply, {:error, %{reason: "reply requires text + session_uris"}}, socket}
  end

  def handle_client_event(_event, _params, socket), do: {:noreply, socket}

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  Returns `{:ok, %{dispatched: [_], failed: [{uri, reason}], skipped: [_]}}`.

  Three buckets per SPEC Invariant #9 / codex r4 closure:

  - `dispatched` — `Ezagent.Invocation.dispatch/1` returned `:ok` or
    `{:ok, _}` (the target Kind was alive and accepted the message).
  - `failed` — dispatch returned `{:error, reason}` (e.g.
    `:no_such_actor` for a stale-but-canonical URI, `:not_ready`,
    `:unauthorized`, `:cross_workspace_denied`). The reason is
    preserved alongside the URI so claude can distinguish "no
    session exists" from "auth denied".
  - `skipped` — `safe_parse_session/1` failed (malformed URI string
    from the client). These never reached dispatch.

  All three buckets are surfaced via Logger.warning + telemetry +
  the channel ACK shape. Silent ACK of a never-delivered reply is
  the Invariant #9 violation this fix eliminates.
  """
  @spec dispatch_reply(URI.t(), [String.t()], String.t(), term(), [map()]) ::
          {:ok,
           %{
             dispatched: [String.t()],
             failed: [{String.t(), term()}],
             skipped: [String.t()]
           }}
  def dispatch_reply(agent_uri, sessions, text, ref, attachments) do
    # `ref` is the opaque 16-hex message id from the cc bridge sidecar
    # (per SPEC v2 §5.13 — message ids are plain UUIDs, NOT URIs). The
    # pre-#438 code wrapped it in `URI.new!/1` and passed `ref:` to
    # `Message.new/3`, but `Message.new/3` only accepts `:ref_id`
    # (string), not `:ref` — so the URI was silently dropped. The
    # #438 sweep over-tightened `URI.new!/1` → `Ezagent.URI.new!/1`
    # and exposed the dead-end path by crashing on the bare hex id.
    # Fix: thread the id through as `:ref_id` (string), as the schema
    # requires. No URI parsing involved.
    ref_id =
      case ref do
        nil -> nil
        "" -> nil
        s when is_binary(s) -> s
      end

    body = %{text: text, attachments: AttachmentNormalizer.normalize_attachments(attachments)}
    msg = Ezagent.Message.new(agent_uri, body, ref_id: ref_id)

    classified =
      Enum.map(sessions, fn session_uri_str ->
        case safe_parse_session(session_uri_str) do
          {:ok, session_uri} ->
            # SPEC 2026-05-27-uri-canonicalization §3.3 + §3.4 —
            # session_uri_str came from the cc bridge WebSocket and was
            # canonicalized via the chokepoint above; URI.new!/1 here
            # consumes the canonical-by-construction string per the
            # §3.4 query-target idiom.
            target = Ezagent.URI.with_action(session_uri, :session, :send)

            result =
              Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                target: target,
                mode: :cast,
                args: %{message: msg},
                ctx: %{
                  caller: agent_uri,
                  authenticated_principal: agent_uri,
                  # The authenticated agent presents only authority already
                  # issued by the target Kind and held durably. This external
                  # bridge is not a signing site and cannot mint authority from
                  # the destination supplied by its client.
                  caps: held_caps(agent_uri),
                  reply: :ignore
                },
                origin: :authenticated_external
              })

            case result do
              :ok -> {:dispatched, session_uri_str}
              {:ok, _} -> {:dispatched, session_uri_str}
              {:error, reason} -> {:failed, session_uri_str, reason}
            end

          :error ->
            {:skipped, session_uri_str}
        end
      end)

    dispatched = for {:dispatched, s} <- classified, do: s
    failed = for {:failed, s, reason} <- classified, do: {s, reason}
    skipped = for {:skipped, s} <- classified, do: s

    # Invariant #9 — boundary input MUST surface via at least one
    # observable channel. We hit three: Logger (operator tail),
    # telemetry (metrics), and the channel ACK shape (claude bridge
    # sees the partial result). Codex r4 caught that {:error, _} from
    # `Invocation.dispatch/1` (e.g. `:no_such_actor` for a stale URI)
    # was previously classified as dispatched; the three-bucket
    # split fixes that silent class.
    if skipped != [] do
      Logger.warning(
        "EzagentPluginCc.BridgeAdapter: dropped #{length(skipped)} malformed " <>
          "session URI(s) from cc bridge reply (agent=#{Ezagent.URI.stable_key(agent_uri)}): " <>
          "#{inspect(skipped)}"
      )

      :telemetry.execute(
        [:ezagent, :plugin_cc, :bridge_adapter, :reply_skipped],
        %{count: length(skipped)},
        %{agent_uri: Ezagent.URI.stable_key(agent_uri), skipped: skipped}
      )
    end

    if failed != [] do
      Logger.warning(
        "EzagentPluginCc.BridgeAdapter: dispatch failed for #{length(failed)} " <>
          "session URI(s) from cc bridge reply (agent=#{Ezagent.URI.stable_key(agent_uri)}): " <>
          "#{inspect(failed)}"
      )

      :telemetry.execute(
        [:ezagent, :plugin_cc, :bridge_adapter, :reply_failed],
        %{count: length(failed)},
        %{agent_uri: Ezagent.URI.stable_key(agent_uri), failed: failed}
      )
    end

    {:ok, %{dispatched: dispatched, failed: failed, skipped: skipped}}
  end

  defp held_caps(%URI{} = agent_uri) do
    if Ezagent.LocalRuntime.kind_alive?(agent_uri) do
      Module.concat([Ezagent, IdentityCaps])
      |> apply(:load, [agent_uri])
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp safe_parse_session(s) when is_binary(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> :error
  end

  defp safe_parse_session(_), do: :error
end
