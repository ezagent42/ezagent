defmodule EzagentPluginFeishu.InboundDispatcher do
  @moduledoc """
  Single entry point shared by `WebhookPlug` and `WsClient`.
  Decoupled from transport.

  Responsibilities (in order):

    1. Resolve sender via `SenderResolver`.
    2. If pending → log + react `THUMBSDOWN` so the human sees ESR
       got the message but ops needs to bind their identity.
    3. If bound → look up session_uri for chat_id via
       `EzagentPluginFeishu.InboundChatLookup.resolve/1` (PR-EM-6 —
       replaces the retired `SessionBinding.resolve/1` reverse-lookup
       and reads from the generic `external_mirror_bindings` table
       maintained by `Ezagent.Behavior.ExternalMirror`).
    4. On bound + session-bound → dispatch
       `<session_uri>?action=chat.send`. On success, react `OK`
       emoji (Allen 2026-05-17 "受到了信息" 反馈).
    5. On dispatch error → send a Feishu text back into the source
       chat explaining what happened, then `THUMBSDOWN` react. The
       bound user IS the delegate; if cap denial or other failure
       happens, surface it to the human, don't silently drop.
       (Allen 2026-05-18 "silent down 不可接受" — PR 27.)

  ## Why a module not a function in WebhookPlug

  Both inbound transports (HTTP webhook + WS long-connect) flow
  through here so we get identical behavior. Pulling it out makes
  the WS module trivial — it just constructs the keyword args list
  and calls `dispatch/1`.

  ## Dispatch mode: `:call`, not `:cast` (Decision #134)

  `Ezagent.Behavior.Chat.@interface[:send]` declares `:send` as `:cast`
  (fire-and-forget). This module dispatches with `mode: :call`
  anyway, so cap-denial or other dispatch failures return
  synchronously as `{:error, _}` and can be surfaced to the human
  via `send_dispatch_error/3`. Legitimate transport-level override
  of the `@interface` default; see Decision #134 +
  `docs/notes/phase-6-architecture-closeout.md` §2.2.
  """

  require Logger

  alias EzagentPluginFeishu.{Client, InboundChatLookup, SenderResolver}

  @type opts :: [
          chat_id: String.t(),
          message_id: String.t() | nil,
          sender: map(),
          body: %{required(:text) => String.t(), required(:attachments) => [map()]}
        ]

  @spec dispatch(opts()) :: :ok | {:error, term()}
  def dispatch(opts) do
    chat_id = Keyword.fetch!(opts, :chat_id)
    message_id = Keyword.get(opts, :message_id)
    sender = Keyword.fetch!(opts, :sender)
    body = Keyword.fetch!(opts, :body)

    case SenderResolver.resolve(sender) do
      {:pending, open_id} ->
        Logger.info(
          "Feishu inbound: open_id=#{open_id} unbound — pending. Run `mix ezagent.feishu.bind #{open_id} entity://user/<name>` to attach."
        )

        # lark react API rejected EYES with code 231001 "reaction type
        # is invalid" — lark only accepts a curated emoji set.
        # THUMBSDOWN is on the supported list and visually distinct
        # from the OK success react below.
        react_safe(message_id, "THUMBSDOWN")
        :ok

      {:ok, caller_uri, caps} ->
        # PR-C of Presence rollout (SPEC `docs/superpowers/specs/2026-05-23-presence.md`
        # rev 3 §7) — mark this user as present via Feishu. Cast through
        # the singleton mirror so the entry rides on a long-lived pid
        # (this process is short-lived per inbound request).
        EzagentPluginFeishu.PresenceMirror.touch(caller_uri)

        case InboundChatLookup.resolve(chat_id) do
          {:ok, session_uri} ->
            case do_dispatch(session_uri, caller_uri, caps, body) do
              :ok ->
                react_safe(message_id, "OK")
                :ok

              {:error, :unauthorized} ->
                # Allen 2026-05-18 "silent down 不可接受": cap denial
                # reaches the human via a text in the original chat +
                # THUMBSDOWN react, not a void log line.
                Logger.info(
                  "Feishu inbound: cap denied for #{URI.to_string(caller_uri)} → " <>
                    "#{URI.to_string(session_uri)}/chat/send; sending text back"
                )

                send_dispatch_error(
                  chat_id,
                  message_id,
                  "THUMBSDOWN",
                  "🚫 ESR: 没有权限发送到 #{URI.to_string(session_uri)} " <>
                    "(missing cap: session.chat). " <>
                    "请联系管理员补一条 `kind=:session behavior=:chat` 的 cap。"
                )

                {:error, :unauthorized}

              {:error, :cross_workspace_denied} ->
                # Phase 9 PR-4 (SPEC v3 §5) — workspace isolation
                # violation. Distinct from :unauthorized per invariant
                # 9: the cap matched structurally, but the caller and
                # target live in different workspaces and the caller
                # doesn't hold a cross-workspace cap. Surface with a
                # different reaction emoji and a workspace-specific
                # failure message so the user understands the root
                # cause is tenant boundary, not missing cap.
                #
                # Reaction emoji "NO" is on Feishu's curated reaction
                # allowlist (https://open.feishu.cn/document/.../emojis);
                # visually distinct from THUMBSDOWN (unauthorized) so
                # operators can grep audit by react. The leading 🌐 in
                # the text body carries the same semantic for the
                # human reader.
                Logger.info(
                  "Feishu inbound: cross-workspace denied for #{URI.to_string(caller_uri)} → " <>
                    "#{URI.to_string(session_uri)}/chat/send; sending text back"
                )

                send_dispatch_error(
                  chat_id,
                  message_id,
                  "NO",
                  "🌐 ESR: 跨 workspace dispatch 被拒绝。" <>
                    "你的身份 (#{URI.to_string(caller_uri)}) 与目标 session " <>
                    "(#{URI.to_string(session_uri)}) 不在同一 workspace。" <>
                    "需要 admin 授予 cross-workspace cap 才能跨 workspace 发送。"
                )

                {:error, :cross_workspace_denied}

              {:error, reason} ->
                Logger.warning(
                  "Feishu inbound dispatch failed: #{inspect(reason)} → sending text back"
                )

                send_dispatch_error(
                  chat_id,
                  message_id,
                  "THUMBSDOWN",
                  "❌ ESR: dispatch 失败: #{inspect(reason)}"
                )

                {:error, reason}
            end

          :error ->
            Logger.info(
              "Feishu inbound: no session binding for chat_id #{chat_id} — drop (no react)"
            )

            {:error, :no_chat_binding}
        end

      {:error, reason} ->
        Logger.warning("Feishu inbound: sender resolve failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_dispatch(session_uri, caller_uri, caps, body) do
    # Phase 6 PR 15: download attachments to local paths so recipients
    # (CC bridge, LV chat thread, future viewers) can show content
    # rather than just metadata. Best-effort — download failure keeps
    # the attachment with type+name only.
    body = Map.update(body, :attachments, [], fn list -> Enum.map(list, &maybe_download/1) end)

    # PR #144 (SPEC v2 §5.8) — origin tag so the FeishuOutbound mirror
    # can detect "this message came IN from Feishu" and skip echoing
    # back to Feishu. The flag is stamped on the body map (which Ecto
    # persists as JSON; key survives round-trip). String key form
    # because MessageStore's load path decodes JSON with string keys
    # and FeishuOutbound matches both shapes.
    body = Map.put(body, :_feishu_origin, true)

    # Phase 6 PR 16: extract @mentions from text (B2 route per Allen
    # 2026-05-17). Resolved live agent URIs go into Message.mentions
    # so the existing MentionRouting matcher routes the message ONLY
    # to the mentioned agent rather than fanning out to all members.
    mentions = EzagentPluginFeishu.MentionParser.extract_agent_mentions(body[:text] || "")

    msg = Ezagent.Message.new(caller_uri, body, mentions: mentions)

    target = URI.parse("#{URI.to_string(session_uri)}?action=chat.send")

    # Allen 2026-05-18: mode :call so cap-denial bubbles back
    # synchronously; the caller (dispatch/1) sends a text message to
    # the human explaining the failure. :cast would silently drop —
    # no audit feedback to the sender.
    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{message: msg},
      ctx: %{caller: caller_uri, caps: caps, reply: :sync}
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # Send a Feishu text back to the source chat when ESR dispatch
  # can't proceed, so the human sees the failure instead of
  # waiting in silence. The react emoji paired with the explanation
  # text mirrors the existing :pending → THUMBSDOWN pattern: emoji
  # for at-a-glance status, text for the "why."
  #
  # Phase 9 PR-4: `react_emoji` argument made explicit so callers can
  # surface different failure modes with different emojis (invariant
  # 9 — :unauthorized vs :cross_workspace_denied vs generic error
  # need to be visually distinguishable at the channel surface).
  defp send_dispatch_error(chat_id, message_id, react_emoji, text) do
    Task.start(fn ->
      case Client.send_text(chat_id, text) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Feishu send_text (dispatch_error) failed: #{inspect(reason)}")
      end
    end)

    react_safe(message_id, react_emoji)
    :ok
  end

  # Best-effort react — failures are non-fatal (network blip on
  # Feishu side shouldn't escalate). `message_id` may be nil for
  # event types without one.
  defp react_safe(nil, _), do: :ok

  # Allen 2026-05-17: react latency was ~seconds because chat/send
  # fan-out fired sync HTTP calls (feishu echo) before this line.
  # Push react into a Task so the user sees ack immediately while
  # ESR is still finishing the fan-out work.
  defp react_safe(message_id, emoji) do
    Task.start(fn ->
      case Client.react(message_id, emoji) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("Feishu react #{emoji} on #{message_id} failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # --- attachment download (moved from WebhookPlug PR 14) ---------------

  defp maybe_download(%{file_key: nil} = att), do: att

  defp maybe_download(%{type: type, file_key: key, message_id: mid, name: name} = att)
       when is_binary(key) and is_binary(mid) do
    feishu_type = feishu_resource_type(type)

    case Client.download_resource(mid, key, feishu_type, name) do
      {:ok, path} ->
        Map.put(att, :local_path, path)

      {:error, reason} ->
        Logger.warning(
          "Feishu inbound: download #{type}/#{name} failed: #{inspect(reason)} — metadata-only forward"
        )

        att
    end
  end

  defp maybe_download(att), do: att

  defp feishu_resource_type(:image), do: "image"
  defp feishu_resource_type(:file), do: "file"
  defp feishu_resource_type(:audio), do: "file"
  defp feishu_resource_type(:video), do: "file"
  defp feishu_resource_type(_), do: "file"
end
