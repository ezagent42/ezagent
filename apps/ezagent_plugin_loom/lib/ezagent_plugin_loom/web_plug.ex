defmodule EzagentPluginLoom.WebPlug do
  @moduledoc """
  Loom customer 入站 transport adapter（清单 B/C：page-SDK 的服务端入口）。

  挂在 `forward "/loom"`(ezagent_web router)。customer 通过 HTTP 跟 loom session 交互:
  - `POST /c/:ws/:sid/messages`  body `{text, token}` —— 发消息进 session(→ auto-started
    OrchestratorServer 编排 → Turn → customer feed)
  - `GET  /c/:ws/:sid/feed?token=` —— 读 visibility-gated customer feed(messages + page)

  **不碰 socialware**:用 socialware 现成 `CustomerAuth`(token 验证)+ `AnonUser`(customer 身份)
  + `CustomerFeed`(受控读)。

  ⚠️ 设计点:socialware 的 anon customer 是 **read-only**(`AnonUser.mint` empty caps),
  customer 入站(发消息)是 socialware 空白。loom 作为受控 transport adapter **代发**:
  token 验证后,以 anon customer 为 message sender、loom gateway 系统身份为 caller(受控 caps)
  dispatch `session.send`。customer 身份只读不变,发消息由受控端点担保 —— adapter 模式,不改
  socialware customer 边界(读仍走 CustomerFeed visibility-gate)。
  """
  use Plug.Router

  alias Ezagent.{Invocation, Message, SystemPrincipal}
  alias Ezagent.Socialware.{AnonBinding, AnonUser, CustomerAuth, CustomerFeed}
  alias Ezagent.Uploads
  alias Ezagent.Uploads.DownloadToken

  alias EzagentPluginLoom.{
    Fork,
    Intent,
    Knowledge,
    Materials,
    Stitch,
    Tool,
    FetchProxy,
    UserSchema
  }

  alias EzagentPluginLoom.{
    MetaAgent,
    WorkerConfig,
    Dashboard,
    SavedTemplates,
    Snapshots,
    PageStore,
    MaterialFiles
  }

  @gateway_uri "system://loom-customer-gateway"

  # loom 真实前端(Next 静态导出,带 Sandpack 预览引擎)。命中真实文件即返回,否则 fall
  # through 到路由 → SPA 兜底 send_index。迁移自 loom-stitch(原本 loom 前端,非占位 SPA)。
  @loom_ui_root "priv/static/loom_ui"

  plug(Plug.Static,
    at: "/",
    from: {:ezagent_plugin_loom, @loom_ui_root},
    only: ["_next", "favicon.ico", "404.html", "index.txt"]
  )

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json, :multipart],
    pass: ["application/json", "multipart/form-data"],
    json_decoder: Jason,
    length: 20_000_000
  )

  plug(:dispatch)

  post "/c/:ws/:sid/messages" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         text when is_binary(text) and text != "" <- conn.body_params["text"],
         {:ok, customer_uri} <- ensure_customer(session_uri),
         {:ok, msg_id} <- send_message(session_uri, customer_uri, text) do
      json(conn, 200, %{ok: true, id: msg_id})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  get "/c/:ws/:sid/feed" do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, session_uri, _ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- conn.query_params["token"],
         {:ok, snapshot} <- CustomerFeed.snapshot(session_uri, token) do
      # per-visitor 页面增强:base page(approved,共享)+ 本访客 ops(前端叠加)
      ops =
        case conn.query_params["visitor"] do
          v when is_binary(v) and v != "" -> UserSchema.ops(session_uri, v)
          _ -> []
        end

      json(conn, 200, %{
        ok: true,
        messages: render_messages(snapshot.messages),
        page: snapshot.page,
        user_schema_ops: ops
      })
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 素材上传(multipart file + token)。落 Uploads.store! + 记进 session 清单。
  post "/c/:ws/:sid/materials/upload" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- conn.body_params["token"],
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         %Plug.Upload{path: tmp, filename: filename} <- conn.body_params["file"] do
      stored = "#{System.unique_integer([:positive])}-#{filename}"
      resource_uri = Uploads.store!(ws, stored, tmp)
      :ok = Materials.register(session_uri, resource_uri, filename)
      json(conn, 200, %{ok: true, uri: URI.to_string(resource_uri), name: filename})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 列素材清单。
  get "/c/:ws/:sid/materials" do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- conn.query_params["token"],
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri) do
      json(conn, 200, %{ok: true, materials: Materials.list(session_uri)})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 受控服务素材文件(download token，红线 #6:不裸 FS 服务)。
  get "/m/:dtoken" do
    with {:ok, %URI{} = resource_uri} <- DownloadToken.verify(dtoken),
         ws when is_binary(ws) <- Ezagent.URI.workspace_name!(resource_uri),
         path when is_binary(path) <- Uploads.path!(resource_uri, %{workspace: ws}) do
      Plug.Conn.send_file(conn, 200, path)
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  # fork:从发布物派生新 loom session。body {token, name, operator_uri}
  post "/c/:ws/:sid/fork" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         name when is_binary(name) and name != "" <- conn.body_params["name"],
         operator when is_binary(operator) <- conn.body_params["operator_uri"],
         {:ok, new_uri} <- Fork.fork(session_uri, name, operator) do
      json(conn, 200, %{ok: true, session: URI.to_string(new_uri)})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      {:error, reason} -> json(conn, 502, %{ok: false, error: inspect(reason)})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # Stitch:发布页 preview 辅助 AI。body {text, token, page?}
  post "/c/:ws/:sid/stitch" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         text when is_binary(text) and text != "" <- conn.body_params["text"],
         sopts = [page: conn.body_params["page"], knowledge: Knowledge.get(session_uri)],
         {:ok, result} <-
           if(conn.body_params["mode"] == "deep",
             do: Stitch.reply_deep(text, sopts),
             else: Stitch.reply(text, sopts)
           ) do
      json(conn, 200, %{ok: true, reply: result.reply, drive: result.drive})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      {:error, _} -> json(conn, 502, %{ok: false, error: "stitch_failed"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # per-visitor 页面增强:追加一个 op。body {visitor, op, token}
  post "/c/:ws/:sid/user-schema" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         visitor when is_binary(visitor) and visitor != "" <- conn.body_params["visitor"],
         op when not is_nil(op) <- conn.body_params["op"] do
      :ok = UserSchema.add(session_uri, visitor, op)
      json(conn, 200, %{ok: true, ops: UserSchema.ops(session_uri, visitor)})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # Dashboard 运营数据(operator)。⚠️ operator-only:当前用 session token,真正 operator auth 待集成。
  get "/c/:ws/:sid/dashboard" do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- conn.query_params["token"],
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri) do
      json(conn, 200, %{ok: true, summary: Dashboard.summary(session_uri)})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 团队管家(meta agent):@自然语言改 team。body {instruction, token}
  post "/c/:ws/:sid/team" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         instruction when is_binary(instruction) and instruction != "" <-
           conn.body_params["instruction"],
         {:ok, result} <- MetaAgent.interpret(session_uri, instruction) do
      json(conn, 200, %{ok: true, result: result})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      {:error, _} -> json(conn, 502, %{ok: false, error: "meta_failed"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 团队 roster 查看。
  get "/c/:ws/:sid/team" do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- conn.query_params["token"],
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri) do
      json(conn, 200, %{ok: true, workers: WorkerConfig.list(session_uri)})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 知识库读(grounding)。
  get "/c/:ws/:sid/knowledge" do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- conn.query_params["token"],
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri) do
      json(conn, 200, %{ok: true, knowledge: Knowledge.get(session_uri)})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 知识库写(编辑者)。body {markdown, token}
  post "/c/:ws/:sid/knowledge" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         md when is_binary(md) <- conn.body_params["markdown"] do
      :ok = Knowledge.put(session_uri, md)
      json(conn, 200, %{ok: true})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 存当前页(page_update span 的 files)为可复用模板(admin "Save as Template")。body {name, token}
  post "/c/:ws/:sid/save-template" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         name when is_binary(name) and name != "" <- conn.body_params["name"],
         page when is_map(page) and map_size(page) > 0 <- current_page(session_uri),
         files when is_map(files) and map_size(files) > 0 <- Map.get(page, "files", page) do
      :ok = SavedTemplates.save(ws, name, files)
      json(conn, 200, %{ok: true, name: name})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "no_page_yet"})
    end
  end

  # 列出本 workspace 已存模板(供"新建 session 时选已存模板"复用)。?token=
  get "/c/:ws/:sid/saved-templates" do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- conn.query_params["token"],
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri) do
      json(conn, 200, %{ok: true, templates: Enum.map(SavedTemplates.list(ws), &%{name: &1.name})})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # page-SDK 工具 RPC(platform.tool)。body {name, args, token}
  post "/c/:ws/:sid/tool" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         name when is_binary(name) <- conn.body_params["name"],
         {:ok, result} <- Tool.invoke(name, conn.body_params["args"] || %{}) do
      json(conn, 200, %{ok: true, result: result})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      {:error, reason} -> json(conn, 400, %{ok: false, error: to_string(reason)})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # page-SDK fetch 代理(platform.fetch,白名单)。body {preset, url, token}
  post "/c/:ws/:sid/fetch" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         preset when is_binary(preset) <- conn.body_params["preset"],
         url when is_binary(url) <- conn.body_params["url"],
         {:ok, resp} <- FetchProxy.fetch(preset, url) do
      json(conn, 200, %{ok: true, status: resp.status, body: resp.body})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      {:error, reason} -> json(conn, 400, %{ok: false, error: to_string(reason)})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # AiSpot ✨ 卡片。body {topic, token}
  post "/c/:ws/:sid/aispot" do
    with {:ok, session_uri, ws_uri} <- uris(ws, sid),
         token when is_binary(token) <- token(conn),
         :ok <- CustomerAuth.authorize(token, session_uri, ws_uri),
         topic when is_binary(topic) and topic != "" <- conn.body_params["topic"],
         {:ok, card} <- Stitch.aispot(topic, knowledge: Knowledge.get(session_uri)) do
      json(conn, 200, %{ok: true, card: card})
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      {:error, _} -> json(conn, 502, %{ok: false, error: "aispot_failed"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
    end
  end

  # 意图推荐(session-less，独有功能)。body {intent, catalog: [%{id,name,desc}]}
  post "/intent" do
    intent = conn.body_params["intent"]
    catalog = conn.body_params["catalog"] || []

    with true <- is_binary(intent) and intent != "",
         true <- is_list(catalog),
         {:ok, picks} <- Intent.recommend(intent, catalog) do
      json(conn, 200, %{ok: true, picks: picks})
    else
      false -> json(conn, 400, %{ok: false, error: "bad_request"})
      {:error, _} -> json(conn, 502, %{ok: false, error: "recommend_failed"})
    end
  end

  # customer 前端壳(SPA)。GET /loom/app/:ws/:sid?token=… 返回单页 HTML。
  get "/app/:ws/:sid" do
    _ = {ws, sid}

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, EzagentPluginLoom.CustomerSPA.html())
  end

  # operator Dashboard 前端壳。GET /loom/dashboard/:ws/:sid?token=…
  get "/dashboard/:ws/:sid" do
    _ = {ws, sid}

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, EzagentPluginLoom.DashboardSPA.html())
  end

  # ── 真实 loom 前端的 API 面(迁移自 loom-stitch;editor 端内部,不走 token)──────
  # 前端(loom_ui)按 loom 原本 contract 调;此处 bridge 到当前 socialware session 的共享
  # infra(MessageStore / Chat 事件 / OrchestratorServer)。Phase 1:load + chat 闭环。
  # frame 格式照搬 loom-stitch(id/sender/role/body/refId),前端识别 page_update span 走预览。

  # 发消息(editor 左栏)→ 进 session(OrchestratorServer 自动编排)。body {text}
  post "/api/:ws/:sid/messages" do
    text = conn.body_params |> Map.get("text", "") |> to_string()

    case loom_send(ws, sid, text) do
      {:ok, id} -> json(conn, 200, %{ok: true, id: id})
      _ -> json(conn, 200, %{ok: false})
    end
  end

  # 历史(最近 50,正序)→ frame 列表(裸 list,同 loom-stitch)。
  get "/api/:ws/:sid/history" do
    json(conn, 200, loom_history(ws, sid))
  end

  # SSE:订阅 session 消息流 → frame。
  get "/api/:ws/:sid/stream" do
    loom_stream(conn, ws, sid)
  end

  # 前端 boot 调;editor 端最小返回。
  get "/whoami" do
    json(conn, 200, %{ok: true, role: "operator"})
  end

  # ── 发布 / 分享(迁移自 loom-stitch;editor 端无 token)──────────────────────
  # 把当前页冻结成不可变快照 → token + 分享链接 /loom/p/<token>。publish 与 snapshot
  # 在迁移版同义(都冻结当前 page_update 页);打开分享链接走 GET /snapshot/:token(只读)
  # 或 POST /p/:token/open|fork(从快照 mint 新 session)。

  post "/api/:ws/:sid/publish" do
    json(conn, 200, loom_freeze(ws, sid))
  end

  post "/api/:ws/:sid/snapshot" do
    json(conn, 200, loom_freeze(ws, sid))
  end

  get "/api/:ws/published" do
    json(conn, 200, %{ok: true, items: Snapshots.list_for_ws(ws)})
  end

  get "/api/:ws/:sid/published" do
    items = Snapshots.list_for_ws(ws) |> Enum.filter(&(&1.published_from == sid))
    json(conn, 200, %{ok: true, items: items})
  end

  get "/snapshot/:token" do
    case Snapshots.get(token) do
      {:ok, snap} ->
        json(conn, 200, %{
          ok: true,
          page: Map.get(snap, "page", %{}),
          ops: Map.get(snap, "ops", []),
          conversation: Map.get(snap, "conversation", []),
          ws: Map.get(snap, "ws"),
          origin_sid: Map.get(snap, "origin_sid")
        })

      :error ->
        json(conn, 200, %{ok: false, error: "unknown token"})
    end
  end

  post "/p/:token/open" do
    json(conn, 200, loom_open_published(token))
  end

  post "/p/:token/fork" do
    json(conn, 200, loom_open_published(token))
  end

  # ── 前端 /api 面(editor 端,无 token;bridge 到现有 loom 模块)──────────────────

  get "/api/:ws/:sid/knowledge" do
    json(conn, 200, %{ok: true, md: Knowledge.get(loom_uri(ws, sid))})
  end

  post "/api/:ws/:sid/knowledge" do
    md =
      (conn.body_params || %{})
      |> Map.get("md", conn.body_params["markdown"] || "")
      |> to_string()

    :ok = Knowledge.put(loom_uri(ws, sid), md)
    json(conn, 200, %{ok: true})
  end

  # worker roster(团队面板):列 / 增改(upsert by key)/ 删。
  get "/api/:ws/:sid/workers" do
    json(conn, 200, %{ok: true, workers: WorkerConfig.list(loom_uri(ws, sid))})
  end

  post "/api/:ws/:sid/workers" do
    su = loom_uri(ws, sid)
    _ = WorkerConfig.add(su, conn.body_params || %{})
    json(conn, 200, %{ok: true, workers: WorkerConfig.list(su)})
  end

  delete "/api/:ws/:sid/workers" do
    su = loom_uri(ws, sid)
    key = Plug.Conn.fetch_query_params(conn).query_params["key"] || ""
    _ = WorkerConfig.remove(su, to_string(key))
    json(conn, 200, %{ok: true, workers: WorkerConfig.list(su)})
  end

  # 编排器自定义指令。
  get "/api/:ws/:sid/orchestrator" do
    json(conn, 200, %{ok: true, instruction: WorkerConfig.get_orchestrator(loom_uri(ws, sid))})
  end

  post "/api/:ws/:sid/orchestrator" do
    instruction = (conn.body_params || %{}) |> Map.get("instruction", "") |> to_string()
    _ = WorkerConfig.put_orchestrator(loom_uri(ws, sid), instruction)
    json(conn, 200, %{ok: true, instruction: instruction})
  end

  # Stitch 接待模式。
  get "/api/:ws/:sid/stitch-mode" do
    json(conn, 200, %{ok: true, mode: WorkerConfig.get_stitch_mode(loom_uri(ws, sid))})
  end

  post "/api/:ws/:sid/stitch-mode" do
    mode = (conn.body_params || %{}) |> Map.get("mode", "stitch") |> to_string()
    _ = WorkerConfig.put_stitch_mode(loom_uri(ws, sid), mode)
    json(conn, 200, %{ok: true, mode: mode})
  end

  # 发布页 session 级 user-schema ops(增强重放)。
  get "/api/:ws/:sid/user-schema" do
    json(conn, 200, %{ok: true, ops: UserSchema.session_ops(loom_uri(ws, sid))})
  end

  post "/api/:ws/:sid/user-schema" do
    su = loom_uri(ws, sid)

    result =
      case conn.body_params do
        %{"ops" => ops} when is_list(ops) -> UserSchema.replace_session_ops(su, ops)
        %{"op" => op} -> UserSchema.append_session_op(su, op)
        _ -> {:error, :missing_op_or_ops}
      end

    case result do
      {:ok, ops} -> json(conn, 200, %{ok: true, ops: ops})
      {:error, reason} -> json(conn, 200, %{ok: false, error: to_string(reason)})
    end
  end

  # 模板:列 / 删 / 从模板建 session。
  get "/api/:ws/templates" do
    json(conn, 200, %{ok: true, items: Enum.map(SavedTemplates.list(ws), &%{name: &1.name})})
  end

  delete "/api/:ws/templates/:name" do
    _ = SavedTemplates.delete(ws, name)
    json(conn, 200, %{ok: true})
  end

  post "/api/:ws/templates/:name/spawn" do
    new_sid =
      (conn.body_params || %{}) |> Map.get("session_name", "") |> to_string() |> String.trim()

    json(conn, 200, loom_spawn_from_template(ws, name, new_sid))
  end

  # 存当前页为模板(前端按钮)。body {name}
  post "/api/:ws/:sid/save-as-template" do
    su = loom_uri(ws, sid)
    name = (conn.body_params || %{}) |> Map.get("name", "") |> to_string() |> String.trim()
    files = current_page(su) |> Map.get("files", %{})

    if name != "" and is_map(files) and map_size(files) > 0 do
      :ok = SavedTemplates.save(ws, name, files)
      json(conn, 200, %{ok: true, name: name})
    else
      json(conn, 200, %{ok: false, error: "no_page_or_name"})
    end
  end

  # page-SDK 工具 / fetch(无 token 版,同 /c 逻辑)。
  post "/api/:ws/:sid/tool" do
    name = conn.body_params["name"]

    case is_binary(name) and Tool.invoke(name, conn.body_params["args"] || %{}) do
      {:ok, result} -> json(conn, 200, %{ok: true, result: result})
      {:error, reason} -> json(conn, 200, %{ok: false, error: to_string(reason)})
      _ -> json(conn, 200, %{ok: false, error: "bad_request"})
    end
  end

  post "/api/:ws/:sid/fetch" do
    preset = conn.body_params["preset"]
    url = conn.body_params["url"]

    case is_binary(preset) and is_binary(url) and FetchProxy.fetch(preset, url) do
      {:ok, resp} -> json(conn, 200, %{ok: true, status: resp.status, body: resp.body})
      {:error, reason} -> json(conn, 200, %{ok: false, error: to_string(reason)})
      _ -> json(conn, 200, %{ok: false, error: "bad_request"})
    end
  end

  # 中断生成(cc one-shot,无持久进程 → no-op)。
  post "/api/:ws/:sid/stop" do
    json(conn, 200, %{ok: true})
  end

  # Stitch(发布页助手)异步:立即 {ok, id},真正 {reply, drive} 由 stitch frame 经 /stream
  # 送达(前端按 refId 关联)。body {text, page?}
  post "/api/:ws/:sid/stitch" do
    su = loom_uri(ws, sid)
    text = (conn.body_params || %{}) |> Map.get("text", "") |> to_string()
    page = conn.body_params["page"]
    deep? = conn.body_params["mode"] == "deep"
    req_id = Snapshots.mint_token()

    Task.start(fn ->
      reply_fn = if deep?, do: &Stitch.reply_deep/2, else: &Stitch.reply/2

      case reply_fn.(text, page: page, knowledge: Knowledge.get(su)) do
        {:ok, %{reply: reply} = r} ->
          emit_stitch_frame(su, ws, sid, req_id, %{
            "reply" => reply,
            "drive" => Map.get(r, :drive),
            "mode" => "stitch"
          })

        _ ->
          :ok
      end
    end)

    json(conn, 200, %{ok: true, id: req_id})
  end

  # AiSpot ✨ 异步:同上,mode=aispot。body {feature, context}
  post "/api/:ws/:sid/aispot" do
    su = loom_uri(ws, sid)
    feature = (conn.body_params || %{}) |> Map.get("feature", "") |> to_string()
    context = (conn.body_params || %{}) |> Map.get("context", "") |> to_string()
    req_id = Snapshots.mint_token()

    Task.start(fn ->
      case Stitch.aispot("#{feature}: #{context}", knowledge: Knowledge.get(su)) do
        {:ok, card} ->
          emit_stitch_frame(su, ws, sid, req_id, %{"card" => card, "mode" => "aispot"})

        _ ->
          :ok
      end
    end)

    json(conn, 200, %{ok: true, id: req_id})
  end

  # GET stitch:读对话线程(从 session 历史的 stitch frame 重建)。
  get "/api/:ws/:sid/stitch" do
    conv =
      loom_uri(ws, sid)
      |> Ezagent.MessageStore.recent_in_session(50)
      |> Enum.reverse()
      |> Enum.map(&loom_frame/1)
      |> Enum.filter(&Map.has_key?(&1, "stitch"))

    json(conn, 200, %{ok: true, conversation: conv})
  end

  # 素材库(目录即库,MaterialFiles 文件树):上传(保留文件夹)/ 列 / 删 / 公开提供。
  post "/api/:ws/:sid/materials/upload" do
    case conn.body_params["file"] do
      %Plug.Upload{path: tmp, filename: fname} ->
        rel = (conn.body_params["path"] || "") |> to_string() |> String.trim()
        rel = if rel == "", do: fname, else: rel

        case MaterialFiles.save_file(ws, sid, rel, tmp) do
          {:ok, saved} -> json(conn, 200, %{ok: true, path: saved})
          {:error, e} -> json(conn, 200, %{ok: false, error: to_string(e)})
        end

      _ ->
        json(conn, 200, %{ok: false, error: "missing file"})
    end
  end

  get "/api/:ws/:sid/materials" do
    items =
      MaterialFiles.list(ws, sid)
      |> Enum.map(&Map.put(&1, "url", "/loom/materials/#{ws}/#{sid}/#{&1["path"]}"))

    json(conn, 200, %{ok: true, items: items})
  end

  delete "/api/:ws/:sid/materials" do
    path = Plug.Conn.fetch_query_params(conn).query_params["path"] || ""
    _ = MaterialFiles.remove(ws, sid, to_string(path))
    json(conn, 200, %{ok: true})
  end

  # 公开提供素材(图片等),v0 生成的页面 `<img src="/loom/materials/<ws>/<sid>/<path>">`。
  get "/materials/:ws/:sid/*path" do
    case MaterialFiles.read(ws, sid, Enum.join(path, "/")) do
      {:ok, bin, rel} ->
        conn
        |> Plug.Conn.put_resp_content_type(mime_for(rel))
        |> Plug.Conn.send_resp(200, bin)

      :error ->
        send_resp(conn, 404, "not found")
    end
  end

  # 未实现的 /api/* → JSON 404(否则被下面 SPA 兜底返回 HTML,前端 r.json() 会崩)。
  match "/api/*_rest" do
    json(conn, 404, %{ok: false, error: "not_implemented"})
  end

  # SPA 兜底:任何其它 GET → index.html(前端按 /loom/<ws>/<sid> 读路由)。
  get "/*_path" do
    send_index(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- helpers --------------------------------------------------------------

  defp send_index(conn) do
    path = Application.app_dir(:ezagent_plugin_loom, "#{@loom_ui_root}/index.html")

    case File.read(path) do
      {:ok, html} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache, must-revalidate")
        |> Plug.Conn.send_resp(200, html)

      {:error, _} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(500, "loom UI 未构建(缺 priv/static/loom_ui/index.html)。")
    end
  end

  # 发消息进 session:以 workspace operator(admin,已是 member)为 sender → chat.send;
  # OrchestratorServer 据此触发编排(Phase 2 v0 → page_update span)。
  defp loom_send(_ws, _sid, ""), do: {:error, :empty}

  defp loom_send(ws, sid, text) do
    session_uri = Ezagent.URI.session(ws, :loom, sid)
    sender = Ezagent.URI.user(ws, "admin")
    send_message(session_uri, sender, text)
  rescue
    _ -> :error
  end

  defp loom_history(ws, sid) do
    Ezagent.URI.session(ws, :loom, sid)
    |> Ezagent.MessageStore.recent_in_session(50)
    |> Enum.reverse()
    |> Enum.map(&loom_frame/1)
  rescue
    _ -> []
  end

  # SSE:订阅 session 事件 topic,把每条 chat_message 作 frame 推给前端。
  defp loom_stream(conn, ws, sid) do
    session_uri = Ezagent.URI.session(ws, :loom, sid)
    topic = Ezagent.Behavior.Session.session_events_topic(session_uri)
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

    conn
    |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.send_chunked(200)
    |> loom_sse_loop()
  end

  defp loom_sse_loop(conn) do
    receive do
      {:chat_message, _src, %Message{} = msg} ->
        case Plug.Conn.chunk(conn, "data: " <> Jason.encode!(loom_frame(msg)) <> "\n\n") do
          {:ok, conn} -> loom_sse_loop(conn)
          {:error, _} -> conn
        end

      _other ->
        loom_sse_loop(conn)
    after
      25_000 ->
        case Plug.Conn.chunk(conn, ": ping\n\n") do
          {:ok, conn} -> loom_sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  # frame 格式照搬 loom-stitch:前端按 sender/role/body 渲染,body 里的 page_update span
  # 由前端识别 → Sandpack 预览(Phase 2 让 v0 产出该 span)。
  defp loom_frame(%Message{} = m) do
    base = %{
      "id" => m.id,
      "sender" => URI.to_string(m.sender),
      "role" => loom_role_of(m.sender),
      "body" => loom_body_text(m.body),
      "refId" => Map.get(m, :ref_id)
    }

    # Stitch / AiSpot worker 回复:body 带 stitch_reply → 随帧作 `stitch` 字段(前端按
    # refId 关联回发起的 Promise,应用 drive/card)。
    case stitch_meta(m.body) do
      nil -> base
      meta -> Map.put(base, "stitch", meta)
    end
  end

  defp stitch_meta(%{stitch_reply: m}) when is_map(m), do: m
  defp stitch_meta(%{"stitch_reply" => m}) when is_map(m), do: m
  defp stitch_meta(_), do: nil

  defp loom_role_of(%URI{} = u), do: loom_role_of(URI.to_string(u))

  defp loom_role_of("entity://" <> rest),
    do: if(String.contains?(rest, "/user/"), do: "user", else: "agent")

  defp loom_role_of(_), do: "unknown"

  defp loom_body_text(%{text: t}) when is_binary(t), do: t
  defp loom_body_text(%{"text" => t}) when is_binary(t), do: t
  defp loom_body_text(_), do: ""

  # 冻结当前页 → 快照 token + 分享链接(publish/snapshot 共用)。
  defp loom_freeze(ws, sid) do
    session_uri = Ezagent.URI.session(ws, :loom, sid)
    # 快照 `page` = **files map**(同 loom-stitch:create_snapshot 存 loom_source=files);
    # 前端只读/消费视图把 `page` 直接当 files 喂 Sandpack。不是 {files,source,summary} 包装。
    files = current_page(session_uri) |> Map.get("files", %{})

    if not is_map(files) or map_size(files) == 0 do
      %{ok: false, error: "no_page_yet"}
    else
      token = Snapshots.mint_token()

      Snapshots.put(token, %{
        "ws" => ws,
        "origin_sid" => sid,
        "page" => files,
        "ops" => [],
        "conversation" => [],
        "knowledge" => Knowledge.get(session_uri) || "",
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      %{ok: true, token: token, link: "/loom/p/#{token}", url: "/loom/p/#{token}"}
    end
  rescue
    e -> %{ok: false, error: inspect(e)}
  end

  # 当前页(权威):优先 PageStore(seed/v0 同步写,= loom-stitch 的 loom_source 语义)→
  # 返回 %{"files"=>...};回退扫消息历史(测试直接注入 span 的场景)。无 → %{}。
  defp current_page(session_uri) do
    case PageStore.get(session_uri) do
      files when is_map(files) and map_size(files) > 0 -> %{"files" => files}
      _ -> current_page_from_history(session_uri)
    end
  end

  # recent_in_session 已是 newest-first,直接 find_value 取最新(不 reverse,否则取到最旧的 seed)。
  defp current_page_from_history(session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(50)
    |> Enum.find_value(%{}, fn m ->
      with text when is_binary(text) <- loom_body_text(m.body),
           [_, json] <- Regex.run(~r/<span type="page_update">([\s\S]*?)<\/span>/, text),
           {:ok, %{} = page} <- Jason.decode(json) do
        page
      else
        _ -> nil
      end
    end)
  rescue
    _ -> %{}
  end

  # 从快照 mint 一个新 loom session(no_seed)+ 发 page_update span(冻结页)→ {ok, ws, sid}。
  defp loom_open_published(token) do
    with {:ok, snap} <- Snapshots.get(token),
         ws when is_binary(ws) <- Map.get(snap, "ws"),
         files when is_map(files) and map_size(files) > 0 <- Map.get(snap, "page", %{}),
         sid = "pub_" <> Snapshots.mint_token(),
         workspace_uri = Ezagent.URI.workspace(ws),
         {:ok, [session_uri | _], _} <-
           EzagentPluginLoom.Template.LoomSession.instantiate(
             "loom-published",
             %{
               "class" => "session.loom",
               "session_name" => sid,
               "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
               "no_seed" => true
             },
             workspace_uri
           ) do
      _ = seed_page_update(session_uri, ws, sid, files)
      %{ok: true, ws: ws, sid: sid}
    else
      :error -> %{ok: false, error: "unknown token"}
      error -> %{ok: false, error: inspect(error)}
    end
  end

  # 把冻结页(files map)包成完整 page_update span({files,source,summary})发进新 session
  # (loomv0 agent 身份)→ 前端从 history/stream 读 .files → Sandpack 渲染。
  defp seed_page_update(session_uri, ws, sid, files) do
    sender = Ezagent.URI.agent(ws, "loomv0_#{sid}")
    PageStore.put(session_uri, files)

    page_map = %{
      "files" => files,
      "source" => Map.get(files, "/App.jsx", ""),
      "summary" => "发布页"
    }

    span = ~s(<span type="page_update">#{Jason.encode!(page_map)}</span>)
    msg = Message.new(sender, %{text: span})

    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: sender,
        caps: SystemPrincipal.caps("system://bootstrap"),
        reply: :ignore
      }
    })
  rescue
    _ -> :ok
  end

  defp uris(ws, sid) do
    {:ok, Ezagent.URI.session(ws, :loom, sid), Ezagent.URI.workspace(ws)}
  rescue
    _ -> :error
  end

  defp loom_uri(ws, sid), do: Ezagent.URI.session(ws, :loom, sid)

  defp mime_for(name) do
    MIME.from_path(name)
  rescue
    _ -> "application/octet-stream"
  end

  # Stitch/AiSpot 回复作 frame 发进 session(loomstitch agent 身份,ref_id 关联请求)→ /stream。
  defp emit_stitch_frame(session_uri, ws, sid, req_id, meta) do
    sender = Ezagent.URI.agent(ws, "loomstitch_#{sid}")
    text = Map.get(meta, "reply") || (Map.get(meta, "card") && "✨") || ""
    msg = Message.new(sender, %{text: to_string(text), stitch_reply: meta}, ref_id: req_id)

    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
      mode: :cast,
      args: %{message: msg},
      ctx: %{caller: sender, caps: SystemPrincipal.caps("system://bootstrap"), reply: :ignore}
    })
  rescue
    _ -> :ok
  end

  # 从已存模板建一个新 loom session(seed 模板的 files)→ {ok, ws, sid}。
  defp loom_spawn_from_template(ws, name, sid) do
    sid = if sid == "", do: "main#{System.unique_integer([:positive])}", else: sid

    with %{tree: _files} <- SavedTemplates.get(ws, name),
         {:ok, [_uri | _], _} <-
           EzagentPluginLoom.Template.LoomSession.instantiate(
             "loom-from-template",
             %{
               "class" => "session.loom",
               "session_name" => sid,
               "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
               "saved_template" => name
             },
             Ezagent.URI.workspace(ws)
           ) do
      %{ok: true, ws: ws, sid: sid}
    else
      nil -> %{ok: false, error: "no_such_template"}
      error -> %{ok: false, error: inspect(error)}
    end
  end

  defp token(conn) do
    case conn.body_params do
      %{"token" => t} when is_binary(t) -> t
      _ -> Plug.Conn.fetch_query_params(conn).query_params["token"]
    end
  end

  # mint 一个只读 anon customer 作 message sender(+ GC binding)。
  defp ensure_customer(session_uri) do
    case AnonUser.mint(session_uri) do
      {:ok, anon_uri} ->
        _ = AnonBinding.touch(anon_uri, session_uri, DateTime.utc_now())
        {:ok, anon_uri}

      error ->
        error
    end
  end

  # 受控代发:sender = anon customer,caller = loom gateway(受控 caps)。
  defp send_message(session_uri, customer_uri, text) do
    msg = Message.new(customer_uri, %{text: text})

    inv = %Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: Ezagent.URI.new!(@gateway_uri),
        caps: SystemPrincipal.caps("system://bootstrap"),
        reply: :ignore
      }
    }

    case Invocation.dispatch(inv) do
      :ok -> {:ok, msg.id}
      {:ok, _} -> {:ok, msg.id}
      error -> error
    end
  end

  defp render_messages(messages) do
    Enum.map(messages, fn m ->
      body = m.body || %{}
      %{id: m.id, text: body["text"] || body[:text], sender: URI.to_string(m.sender)}
    end)
  end

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end
end
