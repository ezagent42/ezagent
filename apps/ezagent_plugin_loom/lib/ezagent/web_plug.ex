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

  # 删除一个 template entry。
  delete "/api/:ws/templates/:name" do
    json_resp(conn, 200, remove_template_entry(ws, name))
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
    EzagentPluginLoom.ClaudeCode.stop(URI.to_string(session_uri(ws, sid)))

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
