defmodule Ezagent.Behavior.LoomStitchWorker do
  @moduledoc """
  Loom stitchworker Behavior — the in-session **preview-side AI**(Stitch 聊天 + AiSpot 卡片)。

  2026-06-10 重构:preview 侧 AI 不再在 `WebPlug` 里直连 DeepSeek。改成 team 里一个
  和 `loomv0` 平级的 `loomstitch_<sid>` worker —— **@-only**(靠 `addressed_to_self?`
  loop-guard,编排器的 decompose 不 @ 它,所以编排器永远调不到),本质仍是 DeepSeek。

  preview 里用户的每句对话 / 每次 ✨ 都由 `WebPlug` 包成一条 `@loomstitch_<sid>` 消息派进
  session;本 worker 收到 → 调 DeepSeek → 回一条 `<span type="stitch_reply">{...}</span>`。
  **对话因此进 MessageStore(session 可见 + 持久化)**,取代旧的 `loom_stitch_chats.json`。

  ## 两种模式(消息 body 的 `stitch.mode`)

  - `"stitch"`:聊天。`system_prompt(caps, kb)` + 历史 → DeepSeek → `parse_reply` 抽
    `{text, drive, op}`。op(addText)落 user_schema;drive 由前端经引擎驱动(不持久化)。
  - `"aispot"`:✨ 卡片。`aispot_prompt(feature, context, kb)` → DeepSeek → 纯文本。

  ## 回复

  `<span type="stitch_reply">{"text", "drive", "op", "mode"}</span>`,`ref_id = 请求 msg.id`
  (前端据此把回帧关联回发起的那次请求 Promise),`mentions = [sender]`。
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  alias Ezagent.{Cmd, Message}
  # 注意命名空间:DeepSeek/Span/Stitch 在 `EzagentPluginLoom.*`;Knowledge/UserSchema
  # 在 `Ezagent.PluginLoom.*`(跟 web_plug 一致)。混了会 :undef 崩。
  alias Ezagent.PluginLoom.{Knowledge, UserSchema}
  alias EzagentPluginLoom.{DeepSeek, Stitch}

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "loom stitchworker — preview-side AI (Stitch chat + AiSpot); reply with `<span type=\"stitch_reply\">` body"
  )

  def required_caps do
    %{receive: Ezagent.Capability.cap(:loomstitch, __MODULE__, :receive)}
  end

  def state_slice, do: :loom_stitch

  def init_slice(_args) do
    %{count: 0, last_error: nil}
  end

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    if addressed_to_self?(msg, ctx) do
      payload = stitch_payload(msg.body)
      {ws, sid} = ws_sid(ctx)
      kb = if ws && sid, do: Knowledge.get(ws, sid), else: ""
      count = ctx[:read].(:count, 0)

      result =
        case Map.get(payload, "mode", "stitch") do
          "aispot" -> run_aispot(payload, kb)
          _ -> run_stitch(payload, kb, ws, sid)
        end

      mode = Map.get(payload, "mode", "stitch")

      case result do
        {:ok, body_map} ->
          {:ok, %{},
           [{:set, :count, count + 1}, {:set, :last_error, nil}] ++
             reply_effect(ctx, msg, body_map["text"] || "好的。", stitch_meta(body_map, mode))}

        {:error, reason} ->
          {:ok, %{},
           [{:set, :last_error, reason}] ++
             reply_effect(
               ctx,
               msg,
               "(增强助手暂时不可用:#{inspect(reason)})",
               %{"mode" => mode, "drive" => nil, "op" => nil}
             )}
      end
    else
      {:ok, %{}, []}
    end
  end

  # ---- 两种模式 --------------------------------------------------------

  defp run_stitch(payload, kb, ws, sid) do
    text = to_string(Map.get(payload, "text", ""))
    caps = Map.get(payload, "caps", []) |> normalize_caps()
    history = Map.get(payload, "history", [])

    messages = Stitch.build_messages(Stitch.system_prompt(caps, kb), history, text)

    case DeepSeek.chat(messages, temperature: 0.3, thinking_disabled: true) do
      {:ok, raw} ->
        {reply, op, drive} = Stitch.parse_reply(raw)

        # op(addText)落 user_schema(消费侧叠加层);drive 不持久化(前端经引擎应用)。
        applied = if op && ws && sid, do: apply_op(ws, sid, op), else: nil

        {:ok, %{"text" => reply, "drive" => drive, "op" => applied, "mode" => "stitch"}}

      {:error, _} = err ->
        err
    end
  end

  defp run_aispot(payload, kb) do
    feature = to_string(Map.get(payload, "feature", ""))
    context = to_string(Map.get(payload, "context", ""))
    caps = Map.get(payload, "caps", []) |> normalize_caps()

    if feature == "" and context == "" do
      {:ok, %{"text" => "(无)", "mode" => "aispot"}}
    else
      sys = Stitch.aispot_prompt(feature, context, kb, caps)

      case DeepSeek.chat(
             [%{"role" => "system", "content" => sys}, %{"role" => "user", "content" => "生成。"}],
             temperature: 0.5,
             thinking_disabled: true
           ) do
        {:ok, text} -> {:ok, %{"text" => text, "mode" => "aispot"}}
        {:error, _} = err -> err
      end
    end
  end

  # ---- payload / 工具 --------------------------------------------------

  # 消息 body 里 worker 用的结构化负载(WebPlug 放在 body 的 `"stitch"` 键)。
  defp stitch_payload(body) when is_map(body), do: body["stitch"] || body[:stitch] || %{}
  defp stitch_payload(_), do: %{}

  defp normalize_caps(caps) when is_list(caps) do
    caps |> Enum.filter(&(is_map(&1) and Map.get(&1, "id") not in [nil, ""])) |> Enum.take(40)
  end

  defp normalize_caps(_), do: []

  defp apply_op(ws, sid, op) do
    op = Map.put_new(op, "id", "op_" <> rand())
    _ = UserSchema.append(ws, sid, op)
    op
  end

  defp rand, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  # 回复的元数据(随帧的独立字段送前端;**不进可见文本** → session/admin 看到的是纯文本)。
  defp stitch_meta(map, mode) do
    %{"mode" => map["mode"] || mode, "drive" => map["drive"], "op" => map["op"]}
  end

  defp ws_sid(ctx) do
    case session_from_ctx(ctx) do
      %URI{path: path} when is_binary(path) ->
        case path |> String.trim_leading("/") |> String.split("/") do
          [ws, sid | _] -> {ws, sid}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  # ---- boilerplate(mention guard + reply dispatch,同 v0)--------------

  defp addressed_to_self?(%Message{mentions: mentions}, %{self_uri: %URI{} = self_uri})
       when is_list(mentions) do
    self_str = URI.to_string(self_uri)

    Enum.any?(mentions, fn
      %URI{} = m -> URI.to_string(m) == self_str
      _ -> false
    end)
  end

  defp addressed_to_self?(_, _), do: false

  defp reply_effect(ctx, %Message{} = req_msg, plain_text, meta)
       when is_binary(plain_text) and is_map(meta) do
    with %URI{} = self_uri <- Map.get(ctx, :self_uri),
         %URI{scheme: "session"} = session_uri <- session_from_ctx(ctx) do
      # 可见 body 是**纯文本**(session/admin 看着干净);drive/op/mode 放 `stitch_reply`
      # 字段,经 SSE 帧的独立字段送前端,不污染聊天文本。
      reply =
        Message.new(self_uri, %{text: plain_text, attachments: [], stitch_reply: meta},
          ref_id: req_msg.id,
          mentions: [req_msg.sender]
        )

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

      cmd =
        Cmd.new(target, :send, %{message: reply}, %{
          caller: self_uri,
          caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
          reply: :ignore
        })

      [{:dispatch, cmd}]
    else
      _ -> []
    end
  end

  defp session_from_ctx(%{caller: %URI{} = u}), do: u

  defp session_from_ctx(%{caller: s}) when is_binary(s) do
    case URI.new(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp session_from_ctx(_), do: nil

  def data_owner(_), do: :no_owner
end
