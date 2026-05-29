defmodule EzagentPluginLoom.WebPlug do
  @moduledoc """
  Loom 前端(`ai-ui-builder`)的 HTTP 入口(2026-05-29 集成,见
  `docs/loom/2026-05-29-frontend-plugin-integration.md`)。

  ## 路由注册(plugin → ezagent_web 的唯一合法触碰)

  `ezagent_web` 的 router.ex 加一行:

      forward "/loom", EzagentPluginLoom.WebPlug

  这是 plugin 对 ezagent_web 的唯一改动,同飞书 `WebhookPlug` 的先例
  (plugin-authoring-contract)。所有逻辑都在本 plug 内。

  ## 它提供什么

  - **静态产物**:`Plug.Static` 把 `priv/static/loom_ui/`(Next 静态导出,
    `basePath:'/loom'`)喂出去。资源在 `/loom/_next/...`、`/loom/favicon.ico`。
  - **页面**:任何 `GET /loom/...` 都返回 `index.html`(SPA 兜底);客户端
    从 `/loom/:workspace/:session_id` 路径读出本页所属 session。
  - **聊天代理**:`POST /loom/api/chat` —— 复用 `EzagentPluginLoom.DeepSeek.chat/2`
    (非流式),前置页面生成系统提示词,一次性返回完整文本(前端
    `useChat({streamProtocol:'text'})` 把整个 body 当一条助手消息)。

  `forward` 剥掉 `/loom` 前缀,故本 plug 内部看到的是相对路径
  (`/_next/...`、`/api/chat`、`/:ws/:sid`)。

  ## 鉴权(v1)

  无。`forward` 在顶层、绕过 `:browser`/`:require_entity` 管线(同飞书
  webhook)。本地 demo 可接受;token/cap 闸是后续(见集成 spec §10)。
  """

  use Plug.Router
  require Logger

  alias EzagentPluginLoom.{DeepSeek, Prompts}

  @loom_ui_root "priv/static/loom_ui"

  # 静态资源:命中真实文件即返回;非文件 fall through 到下面的路由。
  plug(Plug.Static,
    at: "/",
    from: {:ezagent_plugin_loom, @loom_ui_root},
    only: ["_next", "favicon.ico", "404.html", "index.txt"]
  )

  plug(:match)
  plug(:dispatch)

  # 聊天代理(非流式):messages 已被 endpoint 的 Plug.Parsers 解析进
  # conn.body_params(同飞书 WebhookPlug)。
  post "/api/chat" do
    messages = sanitize_messages(conn.body_params)
    sys = %{"role" => "system", "content" => Prompts.page_gen_system_prompt()}

    case DeepSeek.chat([sys | messages], thinking_disabled: true, temperature: 0.7) do
      {:ok, text} ->
        text_resp(conn, 200, text)

      {:error, :no_api_key} ->
        text_resp(conn, 502, "DeepSeek 未配置:phx.server 进程缺 DEEPSEEK_KEY 环境变量。")

      {:error, reason} ->
        Logger.warning("loom WebPlug /api/chat DeepSeek error: #{inspect(reason)}")
        text_resp(conn, 502, "DeepSeek 调用失败,请重试。")
    end
  end

  # --- loom SDK 桥:per-session 端点(同源;沙箱经宿主桥调用)-----------
  # 见 docs/loom/2026-05-29-loom-sdk-bridge.md。

  # 发消息:以稳定临时用户 loomui_<sid> 身份投进 session,自动 @编排器。
  post "/api/:ws/:sid/messages" do
    text = conn.body_params |> Map.get("text", "") |> to_string()
    json_resp(conn, 200, send_to_session(ws, sid, text))
  end

  # 历史消息(最近 50,正序)。
  get "/api/:ws/:sid/history" do
    json_resp(conn, 200, session_history(ws, sid))
  end

  # SSE:订阅 session 全量消息流。
  get "/api/:ws/:sid/stream" do
    stream_session(conn, ws, sid)
  end

  # SPA 兜底:任何 GET 都返回 index.html(客户端从 /loom/:ws/:sid 读身份)。
  get "/*_path" do
    send_index(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- helpers ---------------------------------------------------------

  # useChat 发来的 messages 含 role/content(可能还有 id/parts);只取
  # role + 字符串 content,role 限定 user|assistant|system。
  defp sanitize_messages(%{"messages" => msgs}) when is_list(msgs) do
    msgs
    |> Enum.map(fn
      %{"role" => role, "content" => content} when is_binary(content) ->
        %{"role" => normalize_role(role), "content" => content}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp sanitize_messages(_), do: []

  defp normalize_role(r) when r in ["user", "assistant", "system"], do: r
  defp normalize_role(_), do: "user"

  defp send_index(conn) do
    path = Application.app_dir(:ezagent_plugin_loom, "#{@loom_ui_root}/index.html")

    case File.read(path) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      {:error, _} ->
        text_resp(
          conn,
          500,
          "loom UI 未构建(缺 priv/static/loom_ui/index.html)。" <>
            "见 docs/loom/2026-05-29-frontend-plugin-integration.md 的构建流程。"
        )
    end
  end

  defp text_resp(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  # --- loom SDK 桥 helpers --------------------------------------------

  defp session_uri(ws, sid), do: Ezagent.URI.parse!("session://loom/#{ws}/#{sid}")

  # 发一条消息进 session:稳定临时用户身份 + @编排器(否则 mention-gated 不触发)。
  defp send_to_session(ws, sid, text) do
    suri = session_uri(ws, sid)
    orchestrator = URI.parse("entity://agent/#{ws}/loomorch_#{sid}")

    with {:ok, user_uri} <- EzagentPluginLoom.TempUser.ensure_named(ws, "loomui_#{sid}"),
         :ok <- ensure_joined(suri, user_uri) do
      msg =
        Ezagent.Message.new(user_uri, %{text: text, attachments: []}, mentions: [orchestrator])

      inv = %Ezagent.Invocation{
        target: URI.new!("#{URI.to_string(suri)}?action=chat.send"),
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: user_uri,
          caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
          reply: :ignore
        }
      }

      case Ezagent.Invocation.dispatch(inv) do
        :ok -> %{ok: true, id: msg.id}
        {:ok, _} -> %{ok: true, id: msg.id}
        {:error, reason} -> %{ok: false, error: inspect(reason)}
      end
    else
      {:error, reason} -> %{ok: false, error: inspect(reason)}
    end
  end

  defp ensure_joined(%URI{} = suri, %URI{} = member_uri) do
    inv = %Ezagent.Invocation{
      target: URI.new!("#{URI.to_string(suri)}?action=chat.join"),
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri("session-internal"),
        caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
        reply: {:caller_inbox, self()}
      }
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:join_failed, reason}}
    end
  end

  defp session_history(ws, sid) do
    session_uri(ws, sid)
    |> Ezagent.MessageStore.recent_in_session(50)
    |> Enum.reverse()
    |> Enum.map(&frame/1)
  rescue
    _ -> []
  end

  defp stream_session(conn, ws, sid) do
    topic = Ezagent.Behavior.Chat.session_events_topic(session_uri(ws, sid))
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
    |> sse_loop()
  end

  # SSE 循环:topic 已按 session 隔离,任何 chat_message 都属于本 session。
  # 25s 无消息发一条心跳注释(保活 + 探测断开);chunk 返回 error = 客户端断开。
  defp sse_loop(conn) do
    receive do
      {:chat_message, _src, %Ezagent.Message{} = msg} ->
        case chunk(conn, "data: " <> Jason.encode!(frame(msg)) <> "\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end

      _other ->
        sse_loop(conn)
    after
      25_000 ->
        case chunk(conn, ": ping\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp frame(%Ezagent.Message{} = m) do
    %{
      "id" => m.id,
      "sender" => to_string(m.sender),
      "role" => role_of(m.sender),
      "body" => body_text(m.body),
      "refId" => m.ref_id
    }
  end

  defp role_of(%URI{} = u), do: role_of(URI.to_string(u))
  defp role_of("entity://user/" <> _), do: "user"
  defp role_of("entity://agent/" <> _), do: "agent"
  defp role_of(_), do: "unknown"

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  defp json_resp(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
