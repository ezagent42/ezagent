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

  # NOTE: `EzagentPluginLoom.DeepSeek` and `Prompts.page_gen_system_prompt`
  # are no longer used here — page generation moved to `LoomV0Worker`
  # (2026-06-01 redesign). The bridge endpoints dispatch session actions only.

  @loom_ui_root "priv/static/loom_ui"

  # 静态资源:命中真实文件即返回;非文件 fall through 到下面的路由。
  plug(Plug.Static,
    at: "/",
    from: {:ezagent_plugin_loom, @loom_ui_root},
    only: ["_next", "favicon.ico", "404.html", "index.txt"]
  )

  plug(:match)
  plug(:dispatch)

  # POST /api/chat removed by 2026-06-01 redesign — page generation no longer
  # runs from the standalone left-chat → DeepSeek path; it's now a worker
  # (LoomV0Worker) dispatched by the session orchestrator. See
  # docs/loom/2026-06-01-loom-as-session-redesign.md.

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

  # 停止当前生成:中断该 session 所有在跑的 claude + 清编排器在飞回合(丢弃,不写文件)。
  post "/api/:ws/:sid/stop" do
    json_resp(conn, 200, stop_session(ws, sid))
  end

  # 2026-06-01 save-as-template — snapshot 当前 session 的 :loom_source 进 workspace.session_templates。
  # body: %{"name" => "incubator-portal", "description" => "..可选.."}
  # 流程:read orch slice → build template payload → Workspace.add_template/3
  #       (auto-invokes LoomSession.instantiate → 新 session 在 session://loom/<ws>/<name>)。
  post "/api/:ws/:sid/save-as-template" do
    name = conn.body_params |> Map.get("name", "") |> to_string() |> String.trim()
    description = conn.body_params |> Map.get("description", "") |> to_string()
    json_resp(conn, 200, save_as_template(ws, sid, name, description))
  end

  # 已注册的 template 列表(用于 Phase 2 的 admin UI;也方便 loom UI 检查重名)。
  get "/api/:ws/templates" do
    json_resp(conn, 200, list_loom_templates(ws))
  end

  # 2026-06-05 发布历史:本 ws 下所有 published 模板 + 对应分享链接(新的在前)。
  # loom 发布弹窗用它展示历史,关掉弹窗也能找回链接。
  get "/api/:ws/published" do
    json_resp(conn, 200, %{ok: true, items: list_published_for_ws(ws)})
  end

  # 删除一个 template entry。
  delete "/api/:ws/templates/:name" do
    json_resp(conn, 200, remove_template_entry(ws, name))
  end

  # 2026-06-04 发布(share-link)— 把当前 session 快照成一个**不可变**的
  # published Template Class(自动唯一命名 `pub_<hex>` + 16-hex token),返回
  # 分享链接 `/loom/p/<token>`。每次发布生成新模板+新链接(不可变,不覆盖)。
  # body: %{"description" => "..可选.."}。
  post "/api/:ws/:sid/publish" do
    description = conn.body_params |> Map.get("description", "") |> to_string()
    json_resp(conn, 200, publish_session(ws, sid, description))
  end

  # 2026-06-04 可增强发布页 v0 —— per-session user_schema(操作序列)。
  # base 发布物所有访客共享;每个访客 session 一份 user_schema,引擎在 base 上叠加。
  # GET:读 op 列表(打开页面时拉,重放出该访客之前的增强)。
  get "/api/:ws/:sid/user-schema" do
    json_resp(conn, 200, %{ok: true, ops: Ezagent.PluginLoom.UserSchema.get(ws, sid)})
  end

  # POST:追加一个 op(悬浮框生成后存),返回更新后的完整列表。body: %{"op" => %{...}}
  post "/api/:ws/:sid/user-schema" do
    op = conn.body_params |> Map.get("op")

    case Ezagent.PluginLoom.UserSchema.append(ws, sid, op) do
      {:ok, ops} -> json_resp(conn, 200, %{ok: true, ops: ops})
      {:error, reason} -> json_resp(conn, 200, %{ok: false, error: to_string(reason)})
    end
  end

  # 2026-06-05 Stitch:preview 右下角聊天界面。GET 读对话(打开页面时拉,重放)。
  get "/api/:ws/:sid/stitch" do
    json_resp(conn, 200, %{ok: true, conversation: Ezagent.PluginLoom.StitchChat.get(ws, sid)})
  end

  # POST 发一条消息:接**独立 DeepSeek-v4-flash(非思考)**,回复 + 可能产生一个增强
  # op(如 addText)。两条(user+assistant)都进 StitchChat 持久化;op 进 user_schema。
  # body: %{"text" => "..."}
  post "/api/:ws/:sid/stitch" do
    text = conn.body_params |> Map.get("text", "") |> to_string()
    json_resp(conn, 200, stitch_send(ws, sid, text))
  end

  # 2026-06-05 分享:preview 页"分享"按钮调用。把**当前 preview 会话**的增强状态
  # **冻结成一份副本**(页面 + ops + 浮层对话)→ 新快照 token + 分享链接。
  # copy-on-snapshot:之后用户继续在本页增强不回流到这份快照。
  post "/api/:ws/:sid/snapshot" do
    json_resp(conn, 200, create_snapshot(ws, sid))
  end

  # 2026-06-04 发布链接入口:用 token 对应的不可变模板 mint 一个**全新** session
  # (随机 sid `pub_<hex>`)+ 一个 per-tab 临时用户(`loomui_<sid>`),join 进去,
  # 返回 {ws, sid} 供 preview-only 前端连 SDK 桥。每次打开/刷新都建新 session
  # (token→session 1:多;内部测试阶段接受无界增长,不回收)。
  post "/p/:token/open" do
    json_resp(conn, 200, open_published(token))
  end

  # 2026-06-05 分享快照只读:返回冻结的**页面 + ops + 浮层对话**(均为分享时刻的副本)。
  # 打开分享链接时拉它做只读渲染,不建 session。token 无快照(=发布物 token)→ unknown,
  # 前端据此回退到交互增强(openPublished)。
  # (forward "/loom" 已剥前缀,故路由是 /snapshot/...,前端调 /loom/snapshot/...)
  get "/snapshot/:token" do
    case Ezagent.PluginLoom.Snapshots.get(token) do
      {:ok, snap} ->
        json_resp(conn, 200, %{
          ok: true,
          page: Map.get(snap, "page", %{}),
          ops: Map.get(snap, "ops", []),
          conversation: Map.get(snap, "conversation", []),
          ws: Map.get(snap, "ws"),
          origin_sid: Map.get(snap, "origin_sid")
        })

      :error ->
        json_resp(conn, 200, %{ok: false, error: "unknown token"})
    end
  end

  # 2026-06-05 whoami:从 ezagent 鉴权 session(cookie)解析当前登录身份。loom 路径
  # 绕过 :browser pipeline,但 endpoint 顶层已 `Plug.Session`,故能自行 fetch_session。
  # 前端用它做 fork 闸:未登录 → 跳登录;已登录 → 可 fork。
  get "/whoami" do
    json_resp(conn, 200, whoami(conn))
  end

  # 2026-06-05 fork:从分享快照建一个**自己的**新 session(无 v0,base=快照冻结页面),
  # 把快照 ops 复制进新 session 的 user_schema。浮层对话由前端只读展示。返回 {ws, sid}。
  post "/p/:token/fork" do
    json_resp(conn, 200, fork_published(token))
  end

  # 用模板创建一个新 session(loom UI 自己的"从模板新建"入口,绕过 LV "+ New"
  # 那条不查 recipe 的死路)。body: %{"session_name" => "demo7"}。
  # 后端把 recipe 里的 session_name override 成请求里的,然后直接
  # `LoomSession.instantiate` —— 走 spawn + Team.ensure_team + seed source 全套。
  post "/api/:ws/templates/:name/spawn" do
    new_name = conn.body_params |> Map.get("session_name", "") |> to_string() |> String.trim()
    json_resp(conn, 200, spawn_from_template(ws, name, new_name))
  end

  # --- 2026-06-02 SDK v2 additions ------------------------------------
  # AI 生成的页面可调:文件上传 / 资源下载 / 白名单 fetch / 命名 tool。
  # 见 docs/loom/sdk-v2-additions.md(协议)+ Prompts.page_gen_system_prompt
  # (AI 这边怎么用)。

  # 上传文件:multipart `file` 字段;复用 admin 那套 `resource://uploads/<ws>/<name>`
  # URI shape + 落盘到 Ezagent.Home.path("uploads")。
  # body: multipart `file` (Plug.Upload struct)
  # returns: %{ok: true, uri, name, size, mime} | %{ok: false, error}
  post "/api/:ws/:sid/upload" do
    json_resp(conn, 200, do_upload(conn, ws, sid))
  end

  # 解析 resource:// URI → 302 到 /files/<filename> 下载端点。
  # 强校验:URI 必须 `resource://uploads/<ws>/<file>` 且 <ws> 跟 path param 一致
  # (否则跨工作区资源访问)。
  # query: ?uri=<URL-encoded resource URI>
  get "/api/:ws/:sid/resource" do
    case do_open_resource(conn, ws, sid) do
      {:ok, redirect_to} ->
        conn
        |> put_resp_header("location", redirect_to)
        |> send_resp(302, "")

      {:error, reason} ->
        json_resp(conn, 400, %{ok: false, error: to_string(reason)})
    end
  end

  # 白名单代理 fetch。body: %{preset, url, method?, headers?, body?}
  # returns: %{ok, status?, headers?, body?, truncated?, error?}
  post "/api/:ws/:sid/fetch" do
    json_resp(conn, 200, do_fetch(conn))
  end

  # 命名 tool RPC。body: %{name, args}
  # returns: %{ok: true, result} | %{ok: false, error}
  post "/api/:ws/:sid/tool" do
    json_resp(conn, 200, do_tool(conn, ws, sid))
  end

  # SPA 兜底:任何 GET 都返回 index.html(客户端从 /loom/:ws/:sid 读身份)。
  get "/*_path" do
    send_index(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- helpers ---------------------------------------------------------

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

  defp session_uri(ws, sid), do: Ezagent.URI.new!("session://loom/#{ws}/#{sid}")

  # 停止本 session 的生成:(1) 中断所有在跑的 claude(group=session 字符串);
  # (2) 给编排器发 {:cancel,:all} 清在飞回合(丢弃,不写 :loom_source)。
  defp stop_session(ws, sid) do
    EzagentPluginLoom.LLM.stop(URI.to_string(session_uri(ws, sid)))

    orch_uri = Ezagent.URI.new!("entity://agent/#{ws}/loomorch_#{sid}")

    case Ezagent.KindRegistry.lookup(orch_uri) do
      {:ok, pid} -> send(pid, {:cancel, :all})
      :error -> :ok
    end

    %{ok: true}
  end

  # 2026-06-01 redesign: the loom view has no @-mention concept — every
  # message from this endpoint goes to the session's orchestrator, period.
  # (Power-user "direct @worker" is intentionally NOT exposed in loom; if
  # ever needed, use the `/sessions` admin compose instead.)
  #
  # 2026-06-01 UX fix: prepend `@<orch-id>` to the visible text so the admin
  # session-view shows the @ — routing 还是基于 `mentions` 字段(不依赖文本
  # 解析),前缀只是给人眼看。loom UI 自己的用户气泡也会带上前缀,接受。
  defp send_to_session(ws, sid, text) do
    suri = session_uri(ws, sid)
    orch_id = "loomorch_#{sid}"
    orchestrator = Ezagent.URI.new!("entity://agent/#{ws}/#{orch_id}")

    # 2026-06-01 — 识别消息开头的 @<entity-id>。
    # - 用户写 "@loommeta_<sid> 加 painter" → mentions = [loommeta_<sid>]
    # - 用户写 "改成蓝色" → 默认 mention = orchestrator(老行为)
    # 文本可见层不动 — 让 admin chat 看见用户实际打的字。
    {mentions, visible_text} = parse_mentions(text, ws, sid, orchestrator)

    with {:ok, user_uri} <- EzagentPluginLoom.TempUser.ensure_named(ws, "loomui_#{sid}"),
         :ok <- ensure_joined(suri, user_uri) do
      msg =
        Ezagent.Message.new(
          user_uri,
          %{text: visible_text, attachments: []},
          mentions: mentions
        )

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

  # 2026-06-01 — 提取消息开头的 @<entity-id>(限定 loom 团队里 well-known
  # 命名:loommeta_<sid> / loomorch_<sid> / loomworker_<sid>_<theme> /
  # loomv0_<sid>)。命中 → mentions = [那条 URI],visible_text 保留原样
  # (含 @ 前缀,这样 admin chat 视图看得到)。
  # 没命中(消息不是 @ 开头,或 @ 的不是已知 loom 成员)→ 默认 @ orchestrator,
  # 在 visible_text 前缀 "@<orch-id>" 让 admin 看得清。
  defp parse_mentions(text, ws, sid, orchestrator_uri) do
    valid_ids = [
      "loommeta_#{sid}",
      "loomorch_#{sid}",
      "loomv0_#{sid}"
    ]

    case Regex.run(~r/^\s*@([a-zA-Z_][a-zA-Z0-9_]*)\s*/, text) do
      [_full, target_id] ->
        cond do
          target_id in valid_ids ->
            uri = Ezagent.URI.new!("entity://agent/#{ws}/#{target_id}")
            {[uri], text}

          # 也允许 @loomworker_<sid>_<theme>(自定义 worker 也能直接 @)
          String.starts_with?(target_id, "loomworker_#{sid}_") ->
            uri = Ezagent.URI.new!("entity://agent/#{ws}/#{target_id}")
            {[uri], text}

          true ->
            # @ 了一个不认识的 id → fallback 到 orchestrator,但保留用户写的 @
            {[orchestrator_uri], "@loomorch_#{sid} " <> text}
        end

      nil ->
        # 不是 @ 开头 → 默认 orchestrator,加 @ 前缀让 admin chat 看见
        {[orchestrator_uri], "@loomorch_#{sid} " <> text}
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

  # --- 2026-06-02 SDK v2 helpers -------------------------------------
  # 共享约束:
  # - upload 大小硬上限 20MB(早于读完 multipart);MIME 黑名单(.exe/.bat/.sh)
  # - resource:// URI 必须 `resource://uploads/<ws>/<name>`,<ws> 必须等于
  #   path param 的 ws(防跨工作区资源)
  # - fetch 走 EzagentPluginLoom.FetchProxy(presets + 校验)
  # - tool 走 EzagentPluginLoom.ToolRegistry(name → module + call/2)

  @upload_max_bytes 20 * 1024 * 1024
  @upload_mime_blocklist ["application/x-msdownload", "application/x-msdos-program"]
  @upload_ext_blocklist ~w(.exe .bat .cmd .sh .com .scr .ps1)

  defp do_upload(conn, ws, _sid) do
    case Map.get(conn.body_params, "file") do
      %Plug.Upload{path: tmp_path, filename: original_name, content_type: mime} ->
        with :ok <- check_upload_size(tmp_path),
             :ok <- check_upload_mime(original_name, mime) do
          uuid = Ecto.UUID.generate()
          safe = sanitize_upload_filename(original_name)
          stored_name = "#{uuid}-#{safe}"
          dest = Path.join(Ezagent.Home.path("uploads"), stored_name)
          File.cp!(tmp_path, dest)

          {:ok, %File.Stat{size: size}} = File.stat(dest)
          uri_str = "resource://uploads/#{ws}/#{stored_name}"

          %{
            ok: true,
            uri: uri_str,
            name: original_name,
            size: size,
            mime: mime || "application/octet-stream"
          }
        else
          {:error, reason} -> %{ok: false, error: to_string(reason)}
        end

      _ ->
        %{ok: false, error: "missing or invalid 'file' upload field"}
    end
  rescue
    e -> %{ok: false, error: "upload_failed: #{Exception.message(e)}"}
  end

  defp check_upload_size(tmp_path) do
    case File.stat(tmp_path) do
      {:ok, %File.Stat{size: s}} when s <= @upload_max_bytes -> :ok
      {:ok, _} -> {:error, :file_too_large}
      _ -> {:error, :upload_no_stat}
    end
  end

  defp check_upload_mime(filename, mime) do
    ext = filename |> Path.extname() |> String.downcase()

    cond do
      mime in @upload_mime_blocklist -> {:error, :mime_blocked}
      ext in @upload_ext_blocklist -> {:error, :ext_blocked}
      true -> :ok
    end
  end

  defp sanitize_upload_filename(name) do
    # Same shape as admin's upload sanitizer: keep alnum + - _ . and CJK
    # (UTF-8 multibyte byte ≥ 0x80), replace everything else with "_".
    name
    |> :binary.bin_to_list()
    |> Enum.map(fn b ->
      cond do
        b >= ?a and b <= ?z -> b
        b >= ?A and b <= ?Z -> b
        b >= ?0 and b <= ?9 -> b
        b in [?-, ?_, ?.] -> b
        b >= 0x80 -> b
        true -> ?_
      end
    end)
    |> :binary.list_to_bin()
  end

  defp do_open_resource(conn, ws, _sid) do
    case Map.get(conn_query(conn), "uri") do
      nil ->
        {:error, "missing uri"}

      "" ->
        {:error, "empty uri"}

      uri_str when is_binary(uri_str) ->
        case URI.new(uri_str) do
          {:ok, %URI{scheme: "resource", host: "uploads", path: "/" <> rest}} ->
            case String.split(rest, "/", parts: 2) do
              [^ws, filename] when filename != "" ->
                # 302 to the canonical /files/:filename. The :show endpoint
                # already enforces authz against current_entity_uri — for
                # the loom SDK case, the temp UI user is the uploader so
                # the per-uploader check there will succeed.
                {:ok, "/files/" <> URI.encode(filename)}

              [other_ws, _] ->
                {:error, "cross_workspace_denied: ws=#{ws} vs uri=#{other_ws}"}

              _ ->
                {:error, "bad_resource_uri"}
            end

          _ ->
            {:error, "not_a_resource_upload_uri"}
        end
    end
  end

  defp conn_query(conn) do
    case conn.query_params do
      %Plug.Conn.Unfetched{} -> Plug.Conn.fetch_query_params(conn).query_params
      %{} = q -> q
    end
  end

  defp do_fetch(conn) do
    body = conn.body_params

    preset = body |> Map.get("preset", "") |> to_string()
    url = body |> Map.get("url", "") |> to_string()

    opts =
      body
      |> Map.take(["method", "headers", "body"])
      |> Map.new(fn {k, v} -> {k, v} end)

    case EzagentPluginLoom.FetchProxy.call(preset, url, opts) do
      {:ok, resp} ->
        Map.merge(%{ok: true}, resp)

      {:error, reason} ->
        %{ok: false, error: to_string(reason)}
    end
  rescue
    e -> %{ok: false, error: "fetch_proxy_raised: #{Exception.message(e)}"}
  end

  defp do_tool(conn, ws, sid) do
    name = conn.body_params |> Map.get("name", "") |> to_string()
    args = conn.body_params |> Map.get("args", %{}) |> normalize_args()

    case EzagentPluginLoom.ToolRegistry.lookup(name) do
      {:ok, module} ->
        suri = session_uri(ws, sid)

        ctx = %{
          ws: ws,
          sid: sid,
          session_uri: suri,
          caller: nil
        }

        try do
          case module.call(args, ctx) do
            {:ok, result} -> %{ok: true, result: result}
            {:error, reason} -> %{ok: false, error: to_string(reason)}
            other -> %{ok: false, error: "bad_tool_return: #{inspect(other)}"}
          end
        rescue
          e -> %{ok: false, error: "tool_raised: #{Exception.message(e)}"}
        end

      :error ->
        %{ok: false, error: "unknown tool: #{inspect(name)}"}
    end
  end

  defp normalize_args(args) when is_map(args), do: args
  defp normalize_args(_), do: %{}

  # --- save-as-template helpers ----------------------------------------

  defp save_as_template(_ws, _sid, "", _description),
    do: %{ok: false, error: "name is required"}

  defp save_as_template(ws, sid, name, description) do
    # name 必须像 session short_name(URL 段),否则 session://loom/<ws>/<name> 不合法。
    if name =~ ~r/^[a-zA-Z0-9_-]+$/ do
      do_save_as_template(ws, sid, name, description)
    else
      %{ok: false, error: "name must match [a-zA-Z0-9_-]+"}
    end
  end

  defp do_save_as_template(ws, sid, name, description) do
    # 2026-06-01 Phase 2 — Class 级 + 全队 slice 快照。
    # saved_state shape:
    #   %{ "orchestrator" => %{persona, loom_source},
    #      "workers"      => [%{theme, system_prompt, role}, ...],
    #      "v0"           => %{} }
    # 实例化时 LoomSession.pre_spawn_workers_if_saved 按数组逐个 spawn,
    # Team.ensure_team 用 worker_themes 跑出对应 URI。增/删/改 worker
    # 都通过这个数组持久化(目前无 UI 改动,等 UI 上来自动 work)。
    with {:ok, full_snapshot} <- read_full_session_snapshot(ws, sid),
         {:ok, class_name} <-
           Ezagent.PluginLoom.SavedClasses.save_one(name, full_snapshot, description) do
      %{ok: true, class_name: class_name}
    else
      {:error, reason} -> %{ok: false, error: inspect(reason)}
    end
  end

  # --- 发布 / share-link helpers --------------------------------------

  # 把当前 session 快照成一个不可变 published Template Class + token,返回链接。
  # 复用 save-as-template 的整盘快照(orchestrator persona+loom_source / workers
  # / v0),只是名字自动唯一(`pub_<hex>`,不可覆盖)+ 带 published/token/ws 元数据。
  defp publish_session(ws, sid, description) do
    case read_full_session_snapshot(ws, sid) do
      {:ok, full_snapshot} ->
        token = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
        name = "pub_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

        meta = %{
          "published" => true,
          "token" => token,
          "ws" => ws,
          "published_from" => sid
        }

        # 发布物 = **纯模板**(无快照)。打开它的链接 = 交互增强页(浮层 + 标注 +
        # 分享按钮)。快照由 preview 页的"分享"按钮另行创建(见 create_snapshot/2)。
        case Ezagent.PluginLoom.SavedClasses.save_one(name, full_snapshot, description, meta) do
          {:ok, class_name} ->
            %{ok: true, token: token, link: "/loom/p/#{token}", class_name: class_name}

          {:error, reason} ->
            %{ok: false, error: inspect(reason)}
        end

      {:error, reason} ->
        %{ok: false, error: inspect(reason)}
    end
  end

  # token → 不可变模板 → mint 全新 session(随机 sid)+ per-tab 临时用户 + join。
  # 每次调用都是一个独立访客 session(sid 随机 → loomui_<sid> 自然 per-tab 唯一)。
  defp open_published(token) do
    with {:ok, class_name, ws} <- Ezagent.PluginLoom.SavedClasses.find_by_token(token),
         :ok <- validate_published_ws(ws),
         {:ok, class_module} <- Ezagent.TemplateRegistry.lookup(class_name),
         sid = mint_published_sid(),
         workspace_uri = Ezagent.URI.new!("workspace://#{ws}"),
         tmpl = %{"class" => class_name, "session_name" => sid},
         {:ok, [session_uri | _]} <- class_module.instantiate(sid, tmpl, workspace_uri),
         {:ok, user_uri} <- EzagentPluginLoom.TempUser.ensure_named(ws, "loomui_#{sid}"),
         :ok <- ensure_joined(session_uri, user_uri) do
      %{ok: true, ws: ws, sid: sid}
    else
      :error -> %{ok: false, error: "unknown token"}
      {:error, reason} -> %{ok: false, error: inspect(reason)}
      other -> %{ok: false, error: inspect({:unexpected, other})}
    end
  end

  defp validate_published_ws(ws) when is_binary(ws) and ws != "", do: :ok
  defp validate_published_ws(_), do: {:error, :no_ws_in_published_entry}

  # 从 cookie session 读 current_entity_uri(同 LiveAuth 的 key)。endpoint 顶层
  # 已配 Plug.Session,故 fetch_session 可用。无身份 → logged_in false。
  defp whoami(conn) do
    conn = Plug.Conn.fetch_session(conn)

    case Plug.Conn.get_session(conn, "current_entity_uri") do
      uri when is_binary(uri) and uri != "" ->
        %{ok: true, logged_in: true, entity_uri: uri}

      _ ->
        %{ok: true, logged_in: false}
    end
  rescue
    _ -> %{ok: true, logged_in: false}
  end

  # --- Stitch(独立 DeepSeek-v4-flash 聊天 + 简单增强)-----------------

  @stitch_system_prompt """
  你是 Stitch —— 一个网页增强小助手。用户在浏览一个已发布的网页,想做点小增强或问你点事。
  你能做的操作(目前只有一种):**在页面某个固定位置叠加一段文字**。

  规则:
  - 如果用户想加一段文字,在你回复的**最后另起一行**输出(只一行):
    OP: {"op":"addText","position":"<top|bottom|top-right|top-left|bottom-right|bottom-left>","text":"<要加的文字>"}
    然后用一句话告诉用户你加了什么。
  - 如果用户只是聊天、问问题,正常简短回复,**不要**输出 OP 行。
  - 保持简短、友好、中文。
  """

  defp stitch_send(_ws, _sid, ""), do: %{ok: false, error: "empty text"}

  defp stitch_send(ws, sid, text) do
    user_msg = %{"role" => "user", "text" => text, "id" => stitch_id()}
    _ = Ezagent.PluginLoom.StitchChat.append(ws, sid, user_msg)

    history = Ezagent.PluginLoom.StitchChat.get(ws, sid)

    ds_messages =
      [%{"role" => "system", "content" => @stitch_system_prompt}] ++
        Enum.map(history, fn m -> %{"role" => m["role"], "content" => m["text"]} end)

    # 独立直连 DeepSeek-v4-flash,非思考(不走 LLM 分发器 / 不走会话编排器)。
    case EzagentPluginLoom.DeepSeek.chat(ds_messages, temperature: 0.3, thinking_disabled: true) do
      {:ok, raw} ->
        {reply, op} = parse_stitch_reply(raw)

        _ =
          Ezagent.PluginLoom.StitchChat.append(ws, sid, %{
            "role" => "assistant",
            "text" => reply,
            "id" => stitch_id()
          })

        applied = if op, do: apply_stitch_op(ws, sid, op), else: nil

        %{
          ok: true,
          reply: reply,
          op: applied,
          conversation: Ezagent.PluginLoom.StitchChat.get(ws, sid),
          ops: Ezagent.PluginLoom.UserSchema.get(ws, sid)
        }

      {:error, reason} ->
        # 失败也把一条错误助手消息记进对话,UI 有反馈。
        msg = "(增强助手暂时不可用:#{inspect(reason)})"

        _ =
          Ezagent.PluginLoom.StitchChat.append(ws, sid, %{
            "role" => "assistant",
            "text" => msg,
            "id" => stitch_id()
          })

        %{
          ok: false,
          error: inspect(reason),
          conversation: Ezagent.PluginLoom.StitchChat.get(ws, sid)
        }
    end
  end

  defp apply_stitch_op(ws, sid, op) do
    op = Map.put_new(op, "id", "op_" <> stitch_id())
    _ = Ezagent.PluginLoom.UserSchema.append(ws, sid, op)
    op
  end

  defp stitch_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  # 从 DeepSeek 回复里抽出 `OP: {json}` 行(若有)→ {显示文本, op|nil}。
  defp parse_stitch_reply(raw) when is_binary(raw) do
    lines = String.split(raw, "\n")

    {op_lines, text_lines} =
      Enum.split_with(lines, fn l -> l |> String.trim() |> String.starts_with?("OP:") end)

    op =
      case op_lines do
        [line | _] ->
          json = line |> String.trim() |> String.replace_prefix("OP:", "") |> String.trim()

          case Jason.decode(json) do
            {:ok, %{"op" => _} = o} -> o
            _ -> nil
          end

        _ ->
          nil
      end

    text =
      case text_lines |> Enum.join("\n") |> String.trim() do
        "" -> "好的。"
        t -> t
      end

    {text, op}
  end

  # 从当前 preview 会话冻结快照副本(页面取自 orchestrator 的 loom_source,ops 取自
  # user_schema,**Stitch 对话取自 StitchChat**)。三者都是**副本**:之后 live 会话继续
  # 增强/对话,这份快照不变,被分享者看到的是冻结时刻的状态。
  defp create_snapshot(ws, sid) do
    case read_orchestrator_snapshot(ws, sid) do
      {:ok, %{"loom_source" => page}} ->
        token = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

        Ezagent.PluginLoom.Snapshots.put(token, %{
          "ws" => ws,
          "page" => page,
          "ops" => Ezagent.PluginLoom.UserSchema.get(ws, sid),
          "conversation" => Ezagent.PluginLoom.StitchChat.get(ws, sid),
          "origin_sid" => sid,
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        %{ok: true, token: token, link: "/loom/p/#{token}"}

      {:error, reason} ->
        %{ok: false, error: inspect(reason)}
    end
  end

  # fork:从分享快照建一个**无 v0** 的新 session(用冻结页面作 base)+ 复制快照 ops。
  # base 是快照冻结的页面(经 saved_state.orchestrator.loom_source 注入 + seed);
  # 不依赖原 preview 会话仍存活。
  defp fork_published(token) do
    with {:ok, snap} <- Ezagent.PluginLoom.Snapshots.get(token),
         ws = Map.get(snap, "ws"),
         :ok <- validate_published_ws(ws),
         page = Map.get(snap, "page", %{}),
         sid = mint_published_sid(),
         workspace_uri = Ezagent.URI.new!("workspace://#{ws}"),
         tmpl = %{
           "class" => "session.loom",
           "session_name" => sid,
           "no_v0" => true,
           "saved_state" => %{"orchestrator" => %{"loom_source" => page}}
         },
         {:ok, [session_uri | _]} <-
           Ezagent.PluginLoom.Template.LoomSession.instantiate(
             "session.loom",
             tmpl,
             workspace_uri
           ),
         {:ok, user_uri} <- EzagentPluginLoom.TempUser.ensure_named(ws, "loomui_#{sid}"),
         :ok <- ensure_joined(session_uri, user_uri) do
      # 复制快照 ops + Stitch 对话进新 session(forker 之后改不影响快照)。
      _ = Ezagent.PluginLoom.UserSchema.replace(ws, sid, Map.get(snap, "ops", []))
      _ = Ezagent.PluginLoom.StitchChat.replace(ws, sid, Map.get(snap, "conversation", []))
      %{ok: true, ws: ws, sid: sid}
    else
      :error -> %{ok: false, error: "unknown token"}
      {:error, reason} -> %{ok: false, error: inspect(reason)}
      other -> %{ok: false, error: inspect({:unexpected, other})}
    end
  end

  # 本 ws 的发布历史:每条带分享链接 `/loom/p/<token>`(新的在前)。
  defp list_published_for_ws(ws) do
    Ezagent.PluginLoom.SavedClasses.list_published()
    |> Enum.filter(fn e -> e["ws"] == ws end)
    |> Enum.map(fn e ->
      %{
        token: e["token"],
        link: "/loom/p/#{e["token"]}",
        description: e["description"] || "",
        published_at: e["published_at"],
        published_from: e["published_from"]
      }
    end)
  end

  defp mint_published_sid,
    do: "pub_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  defp read_full_session_snapshot(ws, sid) do
    case read_orchestrator_snapshot(ws, sid) do
      {:ok, orch_snapshot} ->
        workers = read_workers_snapshot(ws, sid)
        v0 = read_v0_snapshot(ws, sid)

        {:ok,
         %{
           "orchestrator" => orch_snapshot,
           "workers" => workers,
           "v0" => v0
         }}

      {:error, _} = err ->
        err
    end
  end

  # 从 session 的 chat.members 里扫所有 loomworker_<sid>_<theme> URI;
  # 对每个 worker 读 :loom_worker slice,出 {theme, system_prompt, role} 三件套。
  # 找不到 session / slice 缺数据 → 空列表(降级到 Team 默认)。
  defp read_workers_snapshot(ws, sid) do
    session_uri = Ezagent.URI.new!("session://loom/#{ws}/#{sid}")

    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, %{members: members}} when is_map(members) ->
        members
        |> Map.keys()
        |> Enum.flat_map(fn member_uri -> snapshot_worker_if_match(member_uri, sid) end)
        |> Enum.sort_by(& &1["theme"])

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp snapshot_worker_if_match(%URI{path: "/" <> rest} = worker_uri, sid)
       when is_binary(rest) do
    case String.split(rest, "/") do
      [_ws, "loomworker_" <> tail] ->
        # tail = "<sid>_<theme>" — split first segment off as sid, rest is theme
        prefix = sid <> "_"

        case String.starts_with?(tail, prefix) do
          true ->
            theme = String.replace_prefix(tail, prefix, "")

            case Ezagent.Kind.get_slice(worker_uri, :loom_worker) do
              {:ok, slice} when is_map(slice) ->
                [
                  %{
                    "theme" => theme,
                    "system_prompt" =>
                      to_string(slice[:system_prompt] || slice["system_prompt"] || ""),
                    "role" => to_string(slice[:role] || slice["role"] || theme)
                  }
                ]

              _ ->
                []
            end

          false ->
            []
        end

      _ ->
        []
    end
  end

  defp snapshot_worker_if_match(_, _), do: []

  # v0 当前 slice 没有 user-meaningful 字段(只有 count / last_error)。
  # 返回空 map 占位,以后 v0 有 user-customizable 状态时填充。
  defp read_v0_snapshot(_ws, _sid), do: %{}

  # 抓 orchestrator slice 的"用户可感知"字段(persona + loom_source);
  # `pending` / `count` / `last_error` 是 runtime 易逝态,不进快照。
  # workers 也不抓 —— 当前 LoomWorker 用 init 默认值,LoomV0Worker 无状态。
  defp read_orchestrator_snapshot(ws, sid) do
    orch_uri = Ezagent.URI.new!("entity://agent/#{ws}/loomorch_#{sid}")

    case Ezagent.Kind.get_slice(orch_uri, :loom_orchestrator) do
      {:ok, slice} when is_map(slice) ->
        persona = slice[:persona] || slice["persona"] || "visitor"
        # 2026-06-02 多文件:loom_source 现为 files map。先判原始值是否"无源",
        # 再归一存 map(不再 to_string)。normalize_source 对 nil/"" 会回退 seed,
        # 所以空判用原始值,避免把 seed 当成用户自定义源快照下来。
        raw = slice[:loom_source] || slice["loom_source"]
        files = EzagentPluginLoom.Prompts.normalize_source(raw)

        cond do
          raw in [nil, "", %{}] or map_size(files) == 0 ->
            {:error, :no_source_in_orchestrator}

          true ->
            {:ok,
             %{
               "persona" => to_string(persona),
               "loom_source" => files
             }}
        end

      {:error, _} = err ->
        err

      other ->
        {:error, {:get_slice_unexpected, inspect(other)}}
    end
  end

  # 2026-06-01 — Class-级:从 SavedClasses JSON 文件读保存项,不再扫
  # workspace.session_templates(那里现在是 Instance 级别,跟保存的 Class 是不同概念)。
  defp list_loom_templates(_ws) do
    Ezagent.PluginLoom.SavedClasses.list_entries()
    # 发布(published)模板是不可变 + 带分享链接的独立概念,不进 loom UI 的
    # 可编辑模板列表(跟手动"生成模板"区分开)。
    |> Enum.reject(& &1["published"])
    |> Enum.map(fn entry ->
      %{
        "name" => entry["name"],
        "summary" => entry["description"] || "",
        "has_custom_source" => true,
        "saved_at" => entry["saved_at"]
      }
    end)
  end

  defp remove_template_entry(_ws, name) do
    # 2026-06-01 — Class-级:从 SavedClasses 删 + deregister 模块。
    case Ezagent.PluginLoom.SavedClasses.delete_one(name) do
      :ok -> %{ok: true}
      {:error, reason} -> %{ok: false, error: inspect(reason)}
    end
  end

  # --- spawn-from-template helpers -------------------------------------

  defp spawn_from_template(_ws, _tmpl_name, ""),
    do: %{ok: false, error: "session_name is required"}

  defp spawn_from_template(ws, tmpl_name, new_session_name) do
    if new_session_name =~ ~r/^[a-zA-Z0-9_-]+$/ do
      do_spawn_from_template(ws, tmpl_name, new_session_name)
    else
      %{ok: false, error: "session_name must match [a-zA-Z0-9_-]+"}
    end
  end

  # 2026-06-01 — Class 级 spawn:`class_name` 是 `session.<saved>`(在
  # `TemplateRegistry` 里能查到 SavedClasses 生成的模块);拿这模块直接
  # instantiate(Module 内部已经把 saved_state 注好,delegate 给 LoomSession)。
  defp do_spawn_from_template(ws, class_name, new_session_name) do
    with {:ok, class_module} <- Ezagent.TemplateRegistry.lookup(class_name),
         :ok <- refuse_if_session_exists(ws, new_session_name),
         tmpl = %{"class" => class_name, "session_name" => new_session_name},
         workspace_uri = Ezagent.URI.new!("workspace://#{ws}"),
         {:ok, [session_uri | _]} <-
           class_module.instantiate(new_session_name, tmpl, workspace_uri) do
      %{ok: true, session_uri: URI.to_string(session_uri)}
    else
      :error -> %{ok: false, error: "class_not_registered"}
      {:error, reason} -> %{ok: false, error: inspect(reason)}
      other -> %{ok: false, error: inspect({:unexpected, other})}
    end
  end

  defp refuse_if_session_exists(ws, name) do
    uri = Ezagent.URI.new!("session://loom/#{ws}/#{name}")

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} -> {:error, :session_already_exists}
      _ -> :ok
    end
  end
end
