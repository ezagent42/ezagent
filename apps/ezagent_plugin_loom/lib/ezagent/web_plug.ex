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
  # are no longer used here — page generation moved to `LoomBuilderWorker`
  # (2026-06-01 redesign). The bridge endpoints dispatch session actions only.

  @loom_ui_root "priv/static/loom_ui"

  # 静态资源:命中真实文件即返回;非文件 fall through 到下面的路由。
  plug(Plug.Static,
    at: "/",
    from: {:ezagent_plugin_loom, @loom_ui_root},
    only: ["_next", "favicon.ico", "404.html", "index.txt"]
  )

  # 2026-06-16 Live2D 看板娘:同源托管模型 + 库(pixi / cubism2 core / pixi-live2d-display)。
  # 浏览器路径 = `/loom/live2d/...`(本 plug forward 在 `/loom` 下)。**故意同源**,不走外部
  # CDN —— 外部源对路线敏感(zuatu.com 那次教训),换网络就缺图。
  plug(Plug.Static,
    at: "/live2d",
    from: {:ezagent_plugin_loom, "priv/static/live2d"},
    only: ["lib", "models"]
  )

  plug(:match)
  plug(:dispatch)

  # POST /api/chat removed by 2026-06-01 redesign — page generation no longer
  # runs from the standalone left-chat → DeepSeek path; it's now a worker
  # (LoomBuilderWorker) dispatched by the session orchestrator. See
  # docs/loom/2026-06-01-loom-as-session-redesign.md.

  # --- loom SDK 桥:per-session 端点(同源;沙箱经宿主桥调用)-----------
  # 见 docs/loom/2026-05-29-loom-sdk-bridge.md。

  # 发消息:以稳定临时用户 loomui_<sid> 身份投进 session,自动 @编排器。
  post "/api/:ws/:sid/messages" do
    text = conn.body_params |> Map.get("text", "") |> to_string()
    json_resp(conn, 200, send_to_session(conn, ws, sid, text))
  end

  # 历史消息(最近 50,正序)。
  get "/api/:ws/:sid/history" do
    # Loom-owned hook hit on every loom-tab load — self-heal a team that a
    # server restart left without its (un-snapshotted) members before the SPA
    # starts streaming, so @mentions land on a live recipient.
    _ = heal_team(ws, sid)
    json_resp(conn, 200, session_history(ws, sid))
  end

  # 2026-06-16 — builder 编辑回退。body: %{"to_id" => "<某条 page_update 消息 id>"}。
  # **不回退 session 历史**:让 builder「再发一条」page_update(append),带那个旧版本的
  # 源码 + 回退说明,并把活动页旁路源码直接回退到该版本。
  post "/api/:ws/:sid/revert" do
    to_id = conn.body_params |> Map.get("to_id", "") |> to_string()
    json_resp(conn, 200, do_revert(ws, sid, to_id))
  end

  # 2026-06-17 — 回退历史(按页):每页「初始版本」+ 最近编辑(共 ≤10/页),最新一条标 current。
  get "/api/:ws/:sid/edit-versions" do
    json_resp(conn, 200, edit_versions(ws, sid))
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

  # 2026-06-12 — 只列**本 session** 发布的(按 published_from 过滤);修「发布历史
  # 在所有 loom session 间共享」的 bug。前端 listPublished 改用这条。
  get "/api/:ws/:sid/published" do
    items = list_published_for_ws(ws) |> Enum.filter(&(&1.published_from == sid))
    json_resp(conn, 200, %{ok: true, items: items})
  end

  # 2026-06-16 — 衍生谱系树:本 ws 下「创作 session → 发布模板 → 冻结消费 / fork」
  # 的层级关系(发布弹窗里展示,让操作员看清谁从谁衍生)。
  get "/api/:ws/lineage" do
    json_resp(conn, 200, %{ok: true, ws: ws, roots: Ezagent.PluginLoom.Lineage.tree(ws)})
  end

  # 2026-06-17 — **本 session** 的衍生谱系(以当前 session 为根的子树),修「不管在哪个
  # session 都看到整个 workspace 的谱系」。发布弹窗改用这条。
  get "/api/:ws/:sid/lineage" do
    json_resp(conn, 200, %{ok: true, ws: ws, roots: Ezagent.PluginLoom.Lineage.tree_for(ws, sid)})
  end

  # 2026-06-17 — 从发布模板**衍生一个全新的、全套可编辑** loom 会话(带 builder + 整个团队 +
  # 多页 + 角色 + 知识库,以模板状态为起点)。区别于打开分享链接(那是冻结消费会话)。
  # body: %{"token" => <发布物 token>, "name" => <新会话名>}。返回 `link` = `/loom/<ws>/<name>`。
  post "/api/:ws/derive" do
    token = conn.body_params |> Map.get("token", "") |> to_string()
    name = conn.body_params |> Map.get("name", "") |> to_string()
    json_resp(conn, 200, derive_editable(token, name))
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

  # POST:写 user_schema。两种 body:
  #   - %{"op" => %{...}}   追加一个 op(如 addText)
  #   - %{"ops" => [...]}   整盘替换(host 对智能组件「状态 op」做按-id-upsert 后回写;
  #                         状态序列 = 操作序列的净结果,刷新/分享重放)
  # 返回更新后的完整列表。
  post "/api/:ws/:sid/user-schema" do
    result =
      case conn.body_params do
        %{"ops" => ops} when is_list(ops) -> Ezagent.PluginLoom.UserSchema.replace(ws, sid, ops)
        %{"op" => op} -> Ezagent.PluginLoom.UserSchema.append(ws, sid, op)
        _ -> {:error, :missing_op_or_ops}
      end

    case result do
      {:ok, ops} -> json_resp(conn, 200, %{ok: true, ops: ops})
      {:error, reason} -> json_resp(conn, 200, %{ok: false, error: to_string(reason)})
    end
  end

  # 2026-06-10 重构:Salesperson / AiSpot 不再直连 DeepSeek。改成把每次请求包成一条
  # `@loomsalesperson_<sid>` 消息**派进 session**,由 salesperson worker(DeepSeek)处理,回帧
  # 经 SSE 流回前端(前端按 ref_id 关联回发起的 Promise)。对话因此进 MessageStore。
  #
  # GET 读对话:从 **session 历史**重建 Salesperson 聊天线程(取代旧 SalespersonChat JSON)。
  get "/api/:ws/:sid/salesperson" do
    json_resp(conn, 200, %{ok: true, conversation: salesperson_conversation(ws, sid)})
  end

  # POST 发一条 Salesperson 聊天:派 `@loomsalesperson_<sid>`(mode=salesperson,带 caps + 最近历史)。
  # 异步——立即返回 `{ok, id}`,真正的 `{reply, drive, op}` 由 worker 回的 salesperson_reply
  # 帧经流送达。body: %{"text", "caps"=[...], "history"=[{role,text,drive}]}
  post "/api/:ws/:sid/salesperson" do
    text = conn.body_params |> Map.get("text", "") |> to_string()
    caps = conn.body_params |> Map.get("caps", []) |> normalize_caps()
    history = conn.body_params |> Map.get("history", [])

    json_resp(
      conn,
      200,
      dispatch_to_salesperson(
        conn,
        ws,
        sid,
        %{"mode" => "salesperson", "text" => text, "caps" => caps, "history" => history},
        text
      )
    )
  end

  # 2026-06-10 AiSpot ✨:同样走 salesperson worker(mode=aispot,纯文本应答)。异步,回帧
  # 经流按 ref_id 关联回那次 ✨ 请求。body: %{"feature", "context"}。
  post "/api/:ws/:sid/aispot" do
    feature = conn.body_params |> Map.get("feature", "") |> to_string()
    context = conn.body_params |> Map.get("context", "") |> to_string()
    caps = conn.body_params |> Map.get("caps", []) |> normalize_caps()

    json_resp(
      conn,
      200,
      dispatch_to_salesperson(
        conn,
        ws,
        sid,
        %{"mode" => "aispot", "feature" => feature, "context" => context, "caps" => caps},
        aispot_visible(feature)
      )
    )
  end

  # 2026-06-09 知识库:编辑器写一段 md,作为消费侧 Salesperson/AiSpot 的 grounding。
  get "/api/:ws/:sid/knowledge" do
    json_resp(conn, 200, %{ok: true, md: Ezagent.PluginLoom.Knowledge.get(ws, sid)})
  end

  # 2026-06-11 意图路由(推荐版):发布页可带 ?intent=<自然语言>。host 收集页面 caps
  # (含 type:"catalog" 的商品目录能力)+ POST 这里,**直连 DeepSeek**(session-less,一次性,
  # 不进会话)→ 从目录里**硬选恰好 3 个**最符合意图的商品 + 写一句推荐语 → 返回 {pitch, slugs}。
  # host 据此 drive 页面到「为你推荐」走马灯(首屏揭开前应用,见 lib/sandbox/intent.ts)。
  post "/intent" do
    text = conn.body_params |> Map.get("text", "") |> to_string()
    caps = conn.body_params |> Map.get("caps", []) |> normalize_caps()
    catalog = extract_catalog(caps)

    cond do
      String.trim(text) == "" or catalog == [] ->
        json_resp(conn, 200, %{ok: false, error: "no_catalog_or_text"})

      true ->
        system = recommend_prompt(catalog)
        messages = [%{role: "system", content: system}, %{role: "user", content: text}]

        case EzagentPluginLoom.DeepSeek.chat(messages, thinking_disabled: true) do
          {:ok, reply} ->
            case parse_recommend(reply, catalog) do
              {pitch, slugs} -> json_resp(conn, 200, %{ok: true, pitch: pitch, slugs: slugs})
              :error -> json_resp(conn, 200, %{ok: false, error: "parse"})
            end

          {:error, reason} ->
            json_resp(conn, 200, %{ok: false, error: inspect(reason)})
        end
    end
  end

  # 从 caps 里抽出 type:"catalog" 能力的商品列表(zuatu App 注册)。每项至少有 slug。
  defp extract_catalog(caps) do
    caps
    |> Enum.find(fn c -> Map.get(c, "type") == "catalog" end)
    |> case do
      %{"products" => ps} when is_list(ps) -> ps
      _ -> []
    end
  end

  defp recommend_prompt(catalog) do
    """
    你是 ZUATU 网店的选品导购。下面是商品目录(JSON 数组,每项有 slug/name/priceText/tag/catLabel):
    #{Jason.encode!(catalog)}

    用户会给一句话表达偏好或意图。请:
    1. 从目录里挑出**最符合**该意图的**恰好 3 个**商品(按相关度排序,最相关在前);
       若强相关不足 3 个,用目录里其它合适的补满 3 个。
    2. 写一句简短有力、像导购当面对她说的中文推荐语(≤28 字,不要书名号)。

    **只返回 JSON,不要任何额外文字 / 不要代码块标记**:
    {"pitch":"……","slugs":["slug1","slug2","slug3"]}
    slugs 里的值必须严格来自目录的 slug 字段。
    """
  end

  # 解析 DeepSeek 回复 → {pitch, slugs(恰好3个有效slug)}。失败 → :error。
  defp parse_recommend(reply, catalog) when is_binary(reply) do
    valid = catalog |> Enum.map(&Map.get(&1, "slug")) |> Enum.filter(&is_binary/1)

    cleaned =
      reply
      |> String.replace(~r/```json|```/, "")
      |> String.trim()

    with {:ok, %{"slugs" => slugs} = m} when is_list(slugs) <- Jason.decode(cleaned) do
      pitch = m |> Map.get("pitch", "为你精选") |> to_string()
      picked = slugs |> Enum.filter(&(&1 in valid)) |> Enum.uniq()
      # 补满 / 截断到 3 个(硬要 3 个)。
      filled = (picked ++ Enum.reject(valid, &(&1 in picked))) |> Enum.take(3)
      if filled == [], do: :error, else: {pitch, filled}
    else
      _ -> :error
    end
  end

  defp parse_recommend(_, _), do: :error

  post "/api/:ws/:sid/knowledge" do
    md = conn.body_params |> Map.get("md", "") |> to_string()

    case Ezagent.PluginLoom.Knowledge.put(ws, sid, md) do
      {:ok, _} -> json_resp(conn, 200, %{ok: true})
      {:error, reason} -> json_resp(conn, 200, %{ok: false, error: to_string(reason)})
    end
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
          # 2026-06-11 — 只读快照视图的 Salesperson 没有 bridge,样式只能靠这里带过去
          # (否则退回默认 fab,丢掉作者配的 bar / accent)。
          salesperson_config: Map.get(snap, "salesperson_config"),
          danmaku_config: Map.get(snap, "danmaku_config"),
          ws: Map.get(snap, "ws"),
          origin_sid: Map.get(snap, "origin_sid"),
          # 多页随快照带走 → 只读视图 ?page= 可达。
          pages: Map.get(snap, "pages")
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

  # 2026-06-15 — 接线员(operator)多 session API。登录身份(cookie)→ 跨 session:
  # 列出「我所在的 session」、往指定 session 发消息(成员身份门控)。builder 可在
  # 发布页上用它做群聊式接线台;发进去的消息也会以弹幕飘在该 session 的预览页。
  get "/api/me/sessions" do
    json_resp(conn, 200, list_my_sessions(conn))
  end

  post "/api/me/send" do
    json_resp(conn, 200, operator_send(conn))
  end

  # 2026-06-17 — 接线员台**按发布版本** scoped:`:ws/:sid` = 接线员当前会话,只列/只发给
  # 「与它同一个发布版本衍生」的会话(同伴集),不再是登录用户加入的所有 session。
  get "/api/:ws/:sid/operator-sessions" do
    json_resp(conn, 200, operator_sessions(conn, ws, sid))
  end

  post "/api/:ws/:sid/operator-send" do
    json_resp(conn, 200, operator_send_scoped(conn, ws, sid))
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

  # resource:// 上传的公开提供(SDK uploadFile / openResource 的图片用)。
  get "/uploads/:name" do
    serve_upload(conn, name)
  end

  # 2026-06-12 — 素材库(目录即库):上传(保留文件夹路径)/ 列 / 删 / 公开提供。
  # 文件落进 `loom_materials/<ws>/<sid>/<rel>`;v0(Claude Code)用 cwd+Read 直接读。
  post "/api/:ws/:sid/materials/upload" do
    json_resp(conn, 200, do_materials_upload(conn, ws, sid))
  end

  get "/api/:ws/:sid/materials" do
    items =
      Ezagent.PluginLoom.Materials.list(ws, sid)
      |> Enum.map(&Map.put(&1, "url", "/loom/materials/#{ws}/#{sid}/#{&1["path"]}"))

    json_resp(conn, 200, %{ok: true, items: items})
  end

  # path 含 `/`,用 query 传(`?path=test1/sub/a.png`)。
  delete "/api/:ws/:sid/materials" do
    path = conn_query(conn) |> Map.get("path", "") |> to_string()
    _ = Ezagent.PluginLoom.Materials.remove(ws, sid, path)
    json_resp(conn, 200, %{ok: true})
  end

  # 2026-06-15 — per-session worker 配置(团队面板)。列 / 增改(upsert by key)/ 删,
  # 改完即把活团队 reconcile 成配置的样子(spawn+join / 换 prompt / leave+terminate)。
  get "/api/:ws/:sid/workers" do
    json_resp(conn, 200, list_workers(ws, sid))
  end

  post "/api/:ws/:sid/workers" do
    json_resp(conn, 200, upsert_worker(conn, ws, sid))
  end

  delete "/api/:ws/:sid/workers" do
    key = conn_query(conn) |> Map.get("key", "") |> to_string()
    json_resp(conn, 200, remove_worker(ws, sid, key))
  end

  # 2026-06-15 — 编排器(loomorch)自定义指令:一段自由文本,影响它怎么拆任务 / 组织回复。
  # 存旁路文件,loomorch 每轮读;不改它的 slice(它持有 loom_source)。
  get "/api/:ws/:sid/orchestrator" do
    json_resp(conn, 200, %{
      ok: true,
      instruction: Ezagent.PluginLoom.WorkerConfig.get_orchestrator(ws, sid)
    })
  end

  post "/api/:ws/:sid/orchestrator" do
    instruction = (conn.body_params || %{}) |> Map.get("instruction", "") |> to_string()
    _ = Ezagent.PluginLoom.WorkerConfig.put_orchestrator(ws, sid, instruction)
    json_resp(conn, 200, %{ok: true, instruction: instruction})
  end

  # 2026-06-15 — Salesperson 接待模式开关:salesperson(自动答访客)| human(不答,出运营分析)。
  get "/api/:ws/:sid/salesperson-mode" do
    json_resp(conn, 200, %{
      ok: true,
      mode: Ezagent.PluginLoom.WorkerConfig.get_salesperson_mode(ws, sid)
    })
  end

  post "/api/:ws/:sid/salesperson-mode" do
    mode = (conn.body_params || %{}) |> Map.get("mode", "salesperson") |> to_string()
    _ = Ezagent.PluginLoom.WorkerConfig.put_salesperson_mode(ws, sid, mode)

    json_resp(conn, 200, %{
      ok: true,
      mode: Ezagent.PluginLoom.WorkerConfig.get_salesperson_mode(ws, sid)
    })
  end

  # 2026-06-16 — 角色门控(发布物隐藏入口)。编辑页配 operator/admin/superadmin 各自的
  # 登录账号 + 目标视图;发布页带 `?role=` 时按 cookie 身份核对。
  get "/api/:ws/:sid/roles" do
    json_resp(conn, 200, roles_get(conn, ws, sid))
  end

  post "/api/:ws/:sid/roles" do
    json_resp(conn, 200, roles_put(conn, ws, sid))
  end

  get "/api/:ws/:sid/role-check" do
    role = conn_query(conn) |> Map.get("role", "") |> to_string()
    json_resp(conn, 200, role_check(conn, ws, sid, role))
  end

  # 2026-06-17 — 列出当前登录身份在该 session 里**符合的全部角色**(按钮)。任何用户(含
  # 发布链接进来的临时未登录用户)都查;登录了就返回他的角色,未登录返回空 + configured 标记
  # (前端据此对未登录者显示登录按钮)。取代旧的 `?role=` 单角色核对。
  get "/api/:ws/:sid/my-roles" do
    json_resp(conn, 200, my_roles(conn, ws, sid))
  end

  # 2026-06-17 — 临时用户升级:注册/登录成功后,正式账号「接管」这个消费会话 ——
  # join 进 session(成员 = 拥有权)+ 把当前 Salesperson 对话历史快照归到账号名下。
  # 底层消息表不改写(临时用户的历史发言原样保留)。须已登录。
  post "/api/:ws/:sid/upgrade-temp" do
    json_resp(conn, 200, upgrade_temp(conn, ws, sid))
  end

  # 角色面板:列房间里的「人」(给账号多选下拉用)。
  get "/api/:ws/:sid/members" do
    json_resp(conn, 200, roster_humans(conn, ws, sid))
  end

  # 2026-06-16 — 多页:发布物默认一页,作者可增删页;builder 改的是「活动页」;发布时全部一起发。
  get "/api/:ws/:sid/pages" do
    json_resp(conn, 200, pages_get(ws, sid))
  end

  # 2026-06-18 — substrate 消费读(取 #810 之长):发布页内容 + 客户可见消息走 socialware
  # `CustomerFeed.snapshot`(visibility-gated、只读 **committed** Surface),token 由
  # `/p/:token/open` 下发。这是消费侧真相从 loom 老存储 cut 到 substrate 的读端点;
  # per-visitor user_schema ops 仍由前端在 base page 上叠加(同 #810)。
  get "/api/:ws/:sid/customer-feed" do
    token = conn_query(conn) |> Map.get("token", "") |> to_string()
    json_resp(conn, 200, customer_feed(ws, sid, token))
  end

  post "/api/:ws/:sid/pages" do
    json_resp(conn, 200, pages_put_meta(ws, sid, conn.body_params || %{}))
  end

  post "/api/:ws/:sid/active-page" do
    id = (conn.body_params || %{}) |> Map.get("id", "") |> to_string()
    json_resp(conn, 200, pages_set_active(ws, sid, id))
  end

  post "/api/:ws/:sid/page-source" do
    body = conn.body_params || %{}

    json_resp(
      conn,
      200,
      pages_put_source(ws, sid, Map.get(body, "id", ""), Map.get(body, "source"))
    )
  end

  # 公开提供素材(图片等),让 v0 生成的 Sandpack 页面能 `<img src="/loom/materials/<ws>/<sid>/<path>">`。
  get "/materials/:ws/:sid/*path" do
    serve_material(conn, ws, sid, Enum.join(path, "/"))
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
        # 2026-06-15 — index.html 必须每次 revalidate。它引用的是 hash 命名的 JS chunk
        # (immutable 长缓存),重建后 chunk 名变;若 index.html 被浏览器启发式缓存,
        # iframe(/loom/:ws/:sid 走这条 SPA 兜底)会一直加载旧 index → 旧 chunk → 看不到新功能。
        |> put_resp_header("cache-control", "no-cache, must-revalidate")
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

  defp session_uri(ws, sid), do: Ezagent.URI.new!("session://#{ws}/loom/#{sid}")

  # ── canonical (backend) ⇄ stitch-layout (frontend) session URI ──
  #
  # The vendored loom SPA is stitch-era: it parses a session-URI STRING as
  # `session://<class>/<ws>/<sid>` (class-first). main's canonical layout is
  # workspace-first `session://<ws>/loom/<sid>`. The message store, cohort and
  # dispatch all speak canonical, but any session URI we *hand the SPA* (and get
  # echoed back) must be in the layout the SPA's parser expects, or it reads the
  # wrong `ws` and navigates to a non-existent session (operator cohort bug).
  #
  # So the WebPlug is the adapter: `fe_session_uri/2` formats OUTbound,
  # `parse_fe_session_uri/1` normalizes INbound back to a canonical %URI{}.

  # Outbound: canonical → SPA layout `session://loom/<ws>/<sid>`.
  defp fe_session_uri(ws, sid), do: "session://loom/#{ws}/#{sid}"

  # Inbound: a session URI string from the SPA → canonical %URI{}. Tolerant of
  # both the SPA's stitch layout (host = "loom", path = "/<ws>/<sid>") and an
  # already-canonical URI (host = <ws>, path = "/loom/<sid>") — no real workspace
  # is named "loom", so host == "loom" unambiguously marks the stitch layout.
  defp parse_fe_session_uri(s) when is_binary(s) and s != "" do
    case Ezagent.URI.new!(s) do
      %URI{scheme: "session", host: "loom", path: "/" <> rest} ->
        case String.split(rest, "/") do
          [ws, sid | _] when ws != "" and sid != "" -> session_uri(ws, sid)
          _ -> nil
        end

      %URI{scheme: "session", host: ws, path: "/" <> rest} when is_binary(ws) and ws != "" ->
        case String.split(rest, "/") do
          [_class, sid | _] when sid != "" -> session_uri(ws, sid)
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_fe_session_uri(_), do: nil

  # Self-heal a loom session's agent team after a server restart.
  #
  # The orchestrator carries a durable snapshot (its slice changes as it works)
  # and its flavor is re-seeded at boot, so it lazy-revives on dispatch. The rest
  # of the team — meta-agent, workers, builder, salesperson — are effectively
  # stateless: they never write a snapshot, so there is nothing to revive them
  # from and a `@mention` to a dead member is delivered to no one.
  #
  # `ensure_team/1` is the idempotent reconciler that (re-)spawns the whole team.
  # Gate on the meta-agent's liveness (present in every loom session, never
  # snapshotted) so the common case — team already alive — costs one registry
  # lookup, and the full reconcile only runs when a member is actually missing.
  # 2026-06-18 vertical cutover: ensure the loom session exists as a unified
  # SocialwareSession (Turn/Surface) on access — opening /loom/:ws/:name
  # auto-creates + seeds it on first open (and revives after restart). Gated on
  # liveness so the common case (already alive) is one registry lookup.
  defp heal_team(ws, sid) do
    # Gate on the meta agent (a team member, never snapshotted → dies on restart
    # while the session itself revives). If it's gone, re-ensure the whole vertical
    # session + team (idempotent: live session/members short-circuit) + seed.
    meta = Ezagent.URI.new!("entity://#{ws}/agent/loommeta_#{sid}")

    case Ezagent.KindRegistry.lookup(meta) do
      {:ok, _pid} ->
        :ok

      :error ->
        _ = Ezagent.PluginLoom.Vertical.ensure_session(ws, sid, nil)
        _ = Ezagent.PluginLoom.Vertical.seed_page(ws, sid, nil)
        :ok
    end
  rescue
    _ -> :ok
  end

  # 停止本 session 的生成:(1) 中断所有在跑的 claude(group=session 字符串);
  # (2) 给编排器发 {:cancel,:all} 清在飞回合(丢弃,不写 :loom_source)。
  defp stop_session(ws, sid) do
    EzagentPluginLoom.LLM.stop(URI.to_string(session_uri(ws, sid)))

    orch_uri = Ezagent.URI.new!("entity://#{ws}/agent/loomorch_#{sid}")

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
  # 2026-06-18 vertical cutover: authoring is the substrate loop —
  # `Vertical.author` records the user message, generates the page (PageGen),
  # lands it in Surface via a Turn (→ customer delivery), and emits the
  # `page_update` message the loom_ui SPA renders. No @-mention / orchestrator
  # agent anymore.
  defp send_to_session(conn, ws, sid, text) do
    suri = session_uri(ws, sid)

    with {:ok, user_uri} <- consumer_sender(conn, ws, sid),
         :ok <- ensure_joined(suri, user_uri) do
      case Ezagent.PluginLoom.Vertical.author(suri, user_uri, to_string(text)) do
        {:ok, resp} -> resp
        {:error, reason} -> %{ok: false, error: inspect(reason)}
      end
    else
      {:error, reason} -> %{ok: false, error: inspect(reason)}
    end
  end

  # 2026-06-01 — 提取消息开头的 @<entity-id>(限定 loom 团队里 well-known
  # 命名:loommeta_<sid> / loomorch_<sid> / loomworker_<sid>_<theme> /
  # loombuilder_<sid>)。命中 → mentions = [那条 URI],visible_text 保留原样
  # (含 @ 前缀,这样 admin chat 视图看得到)。
  # 没命中(消息不是 @ 开头,或 @ 的不是已知 loom 成员)→ 默认 @ orchestrator,
  # 在 visible_text 前缀 "@<orch-id>" 让 admin 看得清。
  defp parse_mentions(text, ws, sid, orchestrator_uri) do
    valid_ids = [
      "loommeta_#{sid}",
      "loomorch_#{sid}",
      "loombuilder_#{sid}",
      "loomsalesperson_#{sid}"
    ]

    case Regex.run(~r/^\s*@([a-zA-Z_][a-zA-Z0-9_]*)\s*/, text) do
      [_full, target_id] ->
        cond do
          target_id in valid_ids ->
            uri = Ezagent.URI.new!("entity://#{ws}/agent/#{target_id}")
            {[uri], text}

          # 也允许 @loomworker_<sid>_<theme>(自定义 worker 也能直接 @)
          String.starts_with?(target_id, "loomworker_#{sid}_") ->
            uri = Ezagent.URI.new!("entity://#{ws}/agent/#{target_id}")
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
      target: Ezagent.URI.with_action(suri, :session, :join),
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
    # The SPA's EventSource auto-reconnects here after a server restart dropped
    # the stream — the most reliable hook to revive an already-open loom tab's
    # (un-snapshotted) team before the user's next @mention.
    _ = heal_team(ws, sid)

    topic = Ezagent.Behavior.Session.session_events_topic(session_uri(ws, sid))
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
    # 也订阅本 session 的 v0 生成进度(ClaudeCode 流式 token 广播到这)。
    Phoenix.PubSub.subscribe(
      EzagentCore.PubSub,
      "loom:gen_progress:" <> URI.to_string(session_uri(ws, sid))
    )

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

      # v0 生成进度增量 → 作 `__loom_progress` 帧推给前端(前端识别后实时显示)。
      {:loom_gen_progress, text} when is_binary(text) ->
        case chunk(
               conn,
               "data: " <> Jason.encode!(%{"__loom_progress" => true, "text" => text}) <> "\n\n"
             ) do
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
    base = %{
      "id" => m.id,
      "sender" => to_string(m.sender),
      "role" => role_of(m.sender),
      "body" => body_text(m.body),
      "refId" => m.ref_id
    }

    # salesperson worker 回复:body 是纯文本,drive/op/mode 在 `salesperson_reply` 字段 → 随帧
    # 作独立 `salesperson` 字段送前端(前端据此应用 drive、关联回 Promise)。
    # salesperson 决策 trace(`salesperson_debug: true`)标 `salespersonDebug` → 前端可据此在消费侧隐藏
    # (编辑器/admin 时间线照常显示纯文本)。GET /salesperson 因其无 salesperson_reply 已自动跳过。
    base = if debug_body?(m.body), do: Map.put(base, "salespersonDebug", true), else: base

    case salesperson_meta_of(m.body) do
      nil -> base
      meta -> Map.put(base, "salesperson", meta)
    end
  end

  defp debug_body?(%{salesperson_debug: true}), do: true
  defp debug_body?(%{"salesperson_debug" => true}), do: true
  defp debug_body?(_), do: false

  defp salesperson_meta_of(%{salesperson_reply: m}) when is_map(m), do: m
  defp salesperson_meta_of(%{"salesperson_reply" => m}) when is_map(m), do: m
  defp salesperson_meta_of(_), do: nil

  # main canonical entity URI is workspace-first `entity://<ws>/<type>/<name>` —
  # host is the workspace, so the role/type is path segment 1 (the FIRST path
  # segment), e.g. entity://system/user/admin → "user".
  defp role_of(%URI{path: "/" <> rest}) do
    case String.split(rest, "/") do
      [type | _] when type in ["user", "agent", "worker"] -> type
      _ -> "unknown"
    end
  end

  defp role_of(s) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, u} -> role_of(u)
      _ -> "unknown"
    end
  end

  defp role_of(_), do: "unknown"

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  defp json_resp(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # 公开提供 uploads/<name>(图片素材等)。name 限定 basename 安全字符,防目录遍历。
  defp serve_upload(conn, name) do
    name = to_string(name)
    path = Path.join(Ezagent.Home.path("uploads"), name)

    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, name) and File.regular?(path) do
      conn
      |> put_resp_content_type(MIME.from_path(name))
      |> put_resp_header("cache-control", "public, max-age=86400")
      |> send_file(200, path)
    else
      json_resp(conn, 404, %{ok: false, error: "not_found"})
    end
  end

  # 素材库上传:文件落进 `loom_materials/<ws>/<sid>/<rel>`(保留文件夹)。
  defp do_materials_upload(conn, ws, sid) do
    case Map.get(conn.body_params, "file") do
      %Plug.Upload{path: tmp, filename: fname, content_type: mime} ->
        with :ok <- check_upload_size(tmp),
             :ok <- check_upload_mime(fname, mime) do
          rel = conn.body_params |> Map.get("path", "") |> to_string() |> String.trim()
          rel = if rel == "", do: fname, else: rel

          case Ezagent.PluginLoom.Materials.save_file(ws, sid, rel, tmp) do
            {:ok, saved} -> %{ok: true, path: saved}
            {:error, e} -> %{ok: false, error: to_string(e)}
          end
        else
          {:error, reason} -> %{ok: false, error: to_string(reason)}
        end

      _ ->
        %{ok: false, error: "missing or invalid 'file' upload field"}
    end
  rescue
    e -> %{ok: false, error: "materials_upload_failed: #{Exception.message(e)}"}
  end

  # 公开提供素材库文件(图片等)。Materials.read 已做相对路径净化(防目录遍历)。
  defp serve_material(conn, ws, sid, path) do
    case Ezagent.PluginLoom.Materials.read(ws, sid, path) do
      {:ok, bin, rel} ->
        conn
        |> put_resp_content_type(MIME.from_path(rel))
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, bin)

      :error ->
        json_resp(conn, 404, %{ok: false, error: "not_found"})
    end
  end

  # --- 2026-06-15 per-session worker 配置 -----------------------------

  defp list_workers(ws, sid) do
    suri = session_uri(ws, sid)
    %{ok: true, workers: Ezagent.PluginLoom.WorkerConfig.get_for_session(suri)}
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp upsert_worker(conn, ws, sid) do
    suri = session_uri(ws, sid)
    body = conn.body_params || %{}

    spec = %{
      "key" => Map.get(body, "key", ""),
      "desc" => Map.get(body, "desc", ""),
      "prompt" => Map.get(body, "prompt", "")
    }

    case Ezagent.PluginLoom.WorkerConfig.upsert(suri, spec) do
      {:ok, list} -> %{ok: true, workers: list}
      {:error, reason} -> %{ok: false, error: to_string(reason)}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp remove_worker(ws, sid, key) do
    suri = session_uri(ws, sid)

    case Ezagent.PluginLoom.WorkerConfig.remove(suri, key) do
      {:ok, list} -> %{ok: true, workers: list}
      {:error, reason} -> %{ok: false, error: to_string(reason)}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
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
            stored_name: stored_name,
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
        case Ezagent.URI.parse(uri_str) do
          {:ok, %URI{scheme: "resource", host: "uploads", path: "/" <> rest}} ->
            case String.split(rest, "/", parts: 2) do
              [^ws, filename] when filename != "" ->
                # main retired the `/files/:filename` route — uploads are served via
                # the signed-capability endpoint `/uploads/download?token=`
                # (Ezagent.Uploads.DownloadToken). loom stores to the SAME core upload
                # layout (uploads/<ws>/<name>), so translate loom's
                # `resource://uploads/<ws>/<name>` shape → main's canonical
                # `resource://<ws>/uploads/<name>`, mint a short-TTL (5min) token,
                # and 302 there (the browser carries the session cookie → RequireEntity
                # + ws-segment authority serve it).
                # TODO(loom-port PR#2): confirm loom's upload WRITE path matches main's
                # FsResolver `uploads` layout on a booted server (PR#1 smoke test).
                canonical = Ezagent.URI.new!("resource://#{ws}/uploads/#{filename}")
                token = Ezagent.Uploads.DownloadToken.mint!(canonical)
                {:ok, "/uploads/download?token=" <> URI.encode(token)}

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
    #      "builder"           => %{} }
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

  # --- 编辑回退 helpers ------------------------------------------------

  # 回退到某条 page_update 版本:不动历史,append 一条 builder 的新 page_update(带旧源),
  # 同时把活动页旁路源码直接回退到该版本(立即生效,编辑器/builder/发布都读旁路)。
  # 回退「初始版本」:to_id = `init:<page>`。
  defp do_revert(ws, sid, "init:" <> page) when is_binary(page) and page != "" do
    case Ezagent.PluginLoom.PageInit.get(ws, sid, page) do
      src when is_map(src) and map_size(src) > 0 ->
        title = page_title(ws, sid, page)
        _ = Ezagent.PluginLoom.Pages.put_source(ws, sid, page, src)
        emit_builder_page_update(ws, sid, src, "↩️ 已把「#{title}」回退到初始版本", page)

      _ ->
        %{ok: false, error: "这一页还没有初始版本(改过一次后才有)"}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp do_revert(ws, sid, to_id) when is_binary(to_id) and to_id != "" do
    suri = session_uri(ws, sid)

    msg =
      suri
      |> Ezagent.MessageStore.recent_in_session(200)
      |> Enum.find(fn %Ezagent.Message{id: id} -> id == to_id end)

    with %Ezagent.Message{} = m <- msg,
         {files, _cfg} when is_map(files) and map_size(files) > 0 <- parse_page_update_msg(m),
         page when is_binary(page) and page != "" <- page_update_msg_page(m) do
      # 回退**这条改的那一页**(page tag),而非当前活动页 —— 用户可能已切到别的页。
      title = page_title(ws, sid, page)
      # 1) 直接把那一页的旁路源码回退(立即生效)。
      _ = Ezagent.PluginLoom.Pages.put_source(ws, sid, page, files)

      # 2) builder append 一条带旧源 + **该页 tag** 的 page_update(不回退历史)→ 编排器 sync
      #    也回写到这页,编辑器若正看着这页则经 onFiles 实时刷新。
      emit_builder_page_update(ws, sid, files, "↩️ 已把「#{title}」回退到这个版本", page)
    else
      nil ->
        %{ok: false, error: "no such page_update version"}

      _ ->
        # 无 page tag = 改 page-tag 之前的老构建,无法确定属于哪一页 → 拒绝(避免串源)。
        %{ok: false, error: "version has no page tag — cannot safely revert (rebuild first)"}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp do_revert(_, _, _), do: %{ok: false, error: "to_id required"}

  # session 某页的标题(展示用);无 → 页 id。
  defp page_title(ws, sid, pageid) do
    case Ezagent.PluginLoom.Pages.get(ws, sid) do
      %{"pages" => pages} ->
        case Enum.find(pages, &(&1["id"] == pageid)) do
          %{"title" => t} when is_binary(t) and t != "" -> t
          _ -> pageid
        end

      _ ->
        pageid
    end
  rescue
    _ -> pageid
  end

  # 回退历史(按页):每页「初始版本」+ 最近编辑(共 ≤10/页),最新一条标 current(= 当前,
  # 点了无意义)。版本来自会话历史里带 page tag 的 page_update;初始版本来自 PageInit。
  defp edit_versions(ws, sid) do
    suri = session_uri(ws, sid)
    pages = pages_get(ws, sid)[:pages] || []
    title_of = Map.new(pages, fn p -> {p["id"], p["title"]} end)

    # 真实版本(新→旧),按页分组。
    by_page =
      suri
      |> Ezagent.MessageStore.recent_in_session(60)
      |> Enum.flat_map(fn m ->
        with {files, _cfg} when is_map(files) and map_size(files) > 0 <- parse_page_update_msg(m),
             page when is_binary(page) and page != "" <- page_update_msg_page(m) do
          [
            %{
              id: m.id,
              page: page,
              summary: page_update_msg_summary(m) || "页面更新",
              at: m.inserted_at && DateTime.to_iso8601(m.inserted_at)
            }
          ]
        else
          _ -> []
        end
      end)
      |> Enum.group_by(& &1.page)

    versions =
      Enum.flat_map(pages, fn p ->
        pid = p["id"]
        title = title_of[pid] || pid

        # 该页最近编辑(新→旧),最多 9 条(留 1 条给初始 → 每页 ≤10)。
        reals =
          by_page
          |> Map.get(pid, [])
          |> Enum.take(9)
          |> Enum.with_index()
          |> Enum.map(fn {v, i} ->
            %{
              "id" => v.id,
              "page" => pid,
              "pageTitle" => title,
              "summary" => v.summary,
              "at" => v.at,
              "current" => i == 0,
              "init" => false
            }
          end)

        init =
          case Ezagent.PluginLoom.PageInit.get(ws, sid, pid) do
            src when is_map(src) and map_size(src) > 0 ->
              [
                %{
                  "id" => "init:" <> pid,
                  "page" => pid,
                  "pageTitle" => title,
                  "summary" => "初始版本",
                  "at" => nil,
                  "current" => false,
                  "init" => true
                }
              ]

            _ ->
              []
          end

        reals ++ init
      end)

    %{ok: true, versions: versions}
  rescue
    e -> %{ok: false, error: Exception.message(e), versions: []}
  end

  # 以 builder 身份往 session 发一条 page_update(@ 编排器),用于回退。带 `page` tag →
  # 编排器 sync 回写到这一页(而非活动页)。
  defp emit_builder_page_update(ws, sid, files, summary, page) do
    suri = session_uri(ws, sid)
    builder_uri = Ezagent.URI.new!("entity://#{ws}/agent/loombuilder_#{sid}")
    orch_uri = Ezagent.URI.new!("entity://#{ws}/agent/loomorch_#{sid}")

    body_text =
      EzagentPluginLoom.Span.span("page_update", %{
        "files" => files,
        "source" => Map.get(files, "/App.jsx", ""),
        "summary" => summary,
        "page" => page
      })

    msg =
      Ezagent.Message.new(
        builder_uri,
        %{text: body_text, attachments: []},
        mentions: [orch_uri]
      )

    inv = %Ezagent.Invocation{
      target: Ezagent.URI.with_action(suri, :session, :send),
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: builder_uri,
        caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
        reply: :ignore
      }
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok -> %{ok: true, id: msg.id}
      {:ok, _} -> %{ok: true, id: msg.id}
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
          "published_from" => sid,
          # 知识库随发布物带走 → 打开链接的消费会话 seed 它(open_published)。
          "knowledge" => Ezagent.PluginLoom.Knowledge.get(ws, sid),
          # 角色门控配置随发布物带走 → 消费会话 seed 它,`?role=` 在发布链接里也查得到。
          "roles" => Ezagent.PluginLoom.RoleConfig.get(ws, sid),
          # 多页随发布物带走(活动页源码用 slice 最新覆盖)→ 消费会话 seed,`?page=` 全可达。
          "pages" => Ezagent.PluginLoom.Pages.bundle(ws, sid, live_active_source(ws, sid))
        }

        # 发布物 = **纯模板**(无快照)。打开它的链接 = 交互增强页(浮层 + 标注 +
        # 分享按钮)。快照由 preview 页的"分享"按钮另行创建(见 create_snapshot/2)。
        case Ezagent.PluginLoom.SavedClasses.save_one(name, full_snapshot, description, meta) do
          {:ok, class_name} ->
            # 谱系:这个模板由 sid(创作 session)发布 → 记一条 published_from。
            _ =
              Ezagent.PluginLoom.Lineage.record_publish(ws, sid, class_name, token, description)

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
         sid = mint_published_sid(),
         workspace_uri = Ezagent.URI.new!("workspace://#{ws}"),
         # Plan B(loom-port):发布物 = 纯数据 → 直接数据驱动实例化 session.loom(冻结),
         # 不再经 TemplateRegistry 查合成模块。
         {:ok, [session_uri | _]} <-
           Ezagent.PluginLoom.SavedClasses.instantiate_from_data(class_name, sid, workspace_uri),
         {:ok, user_uri} <- ensure_consumer_anon(ws, sid),
         :ok <- ensure_joined(session_uri, user_uri) do
      # 知识库随发布物 seed 进这个消费会话 → 它的 Salesperson 也有知识。
      _ =
        Ezagent.PluginLoom.Knowledge.put(
          ws,
          sid,
          Ezagent.PluginLoom.SavedClasses.knowledge_for_token(token)
        )

      # 2026-06-10 — 标记为发布消费会话:它不该有 loom 编辑视图 tab(LoomSessionView)。
      _ = Ezagent.PluginLoom.ConsumerSession.mark(ws, sid)

      # 2026-06-16 — 角色门控随发布物 seed 进消费会话 → `?role=` 在发布链接里查得到。
      _ =
        Ezagent.PluginLoom.RoleConfig.seed(
          ws,
          sid,
          Ezagent.PluginLoom.SavedClasses.roles_for_token(token)
        )

      # 2026-06-16 — 多页随发布物 seed 进消费会话 → `?page=<slug>` 全可达。
      _ =
        Ezagent.PluginLoom.Pages.seed(
          ws,
          sid,
          Ezagent.PluginLoom.SavedClasses.pages_for_token(token)
        )

      # 谱系:这个冻结消费 session 由 class_name 模板 mint → 记一条 derived_from。
      _ = Ezagent.PluginLoom.Lineage.record_consume(ws, sid, class_name)

      # 2026-06-18 — substrate 消费读:发一张 socialware `CustomerAuth` token,前端用它
      # 走 `GET /api/:ws/:sid/customer-feed` 读 committed Surface(已发布页经 `seed_page`
      # 的 turn 落进 Surface)+ 客户可见消息,即消费侧真相走 substrate 而非 loom 老存储。
      customer_token = Ezagent.Socialware.CustomerAuth.issue_token(session_uri, workspace_uri)

      %{ok: true, ws: ws, sid: sid, customer_token: customer_token}
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

  # --- 2026-06-16 角色门控(发布物隐藏入口)helpers ---

  defp caller_entity_str(conn) do
    case caller_entity(conn) do
      {:ok, %URI{} = u} -> URI.to_string(u)
      _ -> nil
    end
  end

  # 2026-06-17 — 消费会话的发言身份:**已登录就用真实账号**,否则用稳定临时用户
  # `loomui_<sid>`。临时用户「升级」(账号接管会话)后,新发言自然归正式账号,而升级前
  # 那段历史发言仍留在临时用户名下(不改写消息表,不碰 core)。
  defp consumer_sender(conn, ws, sid) do
    case caller_entity(conn) do
      {:ok, %URI{scheme: "entity", path: "/user/" <> _} = u} -> {:ok, u}
      _ -> ensure_consumer_anon(ws, sid)
    end
  end

  # 2026-06-18 — 消费身份走 substrate `AnonUser`(只读 anon + `AnonBinding`),取代 loom
  # `TempUser`。每消费会话一个**稳定** anon:首开 mint(`AnonUser.mint`)+ 绑定
  # (`AnonBinding.touch`)+ 存进 `ConsumerSession`,后续复用同一个。任何一步失败 →
  # fallback 回 `TempUser`,保证消费/导购/接线员等已验流程不被身份迁移破坏。
  # 发送权限来自 `system://session-internal`(非 user caps),故只读 anon 作发送者 URI 无碍。
  defp ensure_consumer_anon(ws, sid) do
    case Ezagent.PluginLoom.ConsumerSession.anon(ws, sid) do
      a when is_binary(a) ->
        anon_uri = Ezagent.URI.new!(a)
        _ = Ezagent.SpawnRegistry.spawn(anon_uri)
        {:ok, anon_uri}

      _ ->
        session_uri = session_uri(ws, sid)

        with {:ok, anon_uri} <- Ezagent.Socialware.AnonUser.mint(session_uri),
             _ <- Ezagent.SpawnRegistry.spawn(anon_uri),
             _ <- Ezagent.Socialware.AnonBinding.touch(anon_uri, session_uri, DateTime.utc_now()) do
          _ = Ezagent.PluginLoom.ConsumerSession.put_anon(ws, sid, URI.to_string(anon_uri))
          {:ok, anon_uri}
        else
          _ -> EzagentPluginLoom.TempUser.ensure_named(ws, "loomui_#{sid}")
        end
    end
  rescue
    _ -> EzagentPluginLoom.TempUser.ensure_named(ws, "loomui_#{sid}")
  end

  # 编辑页读角色配置。作者首次打开面板 → 捕获创建者(= 超级管理员)。
  defp roles_get(conn, ws, sid) do
    who = caller_entity_str(conn)
    cfg = Ezagent.PluginLoom.RoleConfig.ensure_creator(ws, sid, who)
    %{ok: true, logged_in: who != nil, entity_uri: who, roles: cfg}
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  # 编辑页写角色配置(整盘 `%{"super"=>..., "roles"=>[...]}`;creator 服务端保留)。
  defp roles_put(conn, ws, sid) do
    body = conn.body_params || %{}
    # 顺手补一次创建者捕获(万一 GET 时还没登录)。
    if who = caller_entity_str(conn),
      do: Ezagent.PluginLoom.RoleConfig.ensure_creator(ws, sid, who)

    case Ezagent.PluginLoom.RoleConfig.put(ws, sid, body) do
      {:ok, cfg} -> %{ok: true, roles: cfg}
      {:error, e} -> %{ok: false, error: to_string(e)}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  # 编辑页:列出房间里的「人」(entity://user/...,含作者自己),给角色面板的账号下拉用。
  # 排除 AI(entity://agent/...)和 session 自身。session 没活着 → 空列表(降级)。
  defp roster_humans(_conn, ws, sid) do
    suri = Ezagent.URI.new!("session://#{ws}/loom/#{sid}")

    members =
      case Ezagent.Kind.get_slice(suri, :session) do
        {:ok, %{members: m}} when is_map(m) -> Map.keys(m)
        _ -> []
      end

    people =
      members
      |> Enum.map(&member_uri_str/1)
      |> Enum.filter(&(role_of(&1) == "user"))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn uri -> %{uri: uri, name: uri |> String.split("/") |> List.last()} end)

    %{ok: true, members: people}
  rescue
    e -> %{ok: false, error: Exception.message(e), members: []}
  end

  # --- 2026-06-16 多页 helpers ---

  # 活动页的**实时**源码(slice / 最新 page_update);无 → 空 map。
  defp live_active_source(ws, sid) do
    case read_orchestrator_snapshot(ws, sid) do
      {:ok, %{"loom_source" => files}} when is_map(files) -> files
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # 读多页结构。活动页源码用 slice 的最新覆盖(保证编辑器切回活动页时是最新)。
  defp pages_get(ws, sid) do
    alias_p = Ezagent.PluginLoom.Pages
    live = live_active_source(ws, sid)
    data = alias_p.bundle(ws, sid, live)
    %{ok: true, active: data["active"], pages: data["pages"]}
  rescue
    e -> %{ok: false, error: Exception.message(e), active: "home", pages: []}
  end

  # 2026-06-18 — substrate 消费读:经 socialware `CustomerFeed.snapshot` 取 committed
  # Surface 的页面 + 客户可见消息(token 内部鉴权,visibility-gated)。这是消费侧从
  # loom 老存储 cut 到 substrate 真相的读路径。
  defp customer_feed(ws, sid, token) do
    session_uri = session_uri(ws, sid)

    case Ezagent.Socialware.CustomerFeed.snapshot(session_uri, token) do
      {:ok, %{page: page, messages: messages}} ->
        %{ok: true, page: page, messages: messages}

      {:error, reason} ->
        %{ok: false, error: to_string(reason)}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  # 写元数据(增删/改名/salesperson 开关)。默认页源码兜底用 slice 最新。
  defp pages_put_meta(ws, sid, body) do
    case Ezagent.PluginLoom.Pages.put_meta(ws, sid, body, live_active_source(ws, sid)) do
      {:ok, data} -> %{ok: true, active: data["active"], pages: data["pages"]}
      {:error, e} -> %{ok: false, error: to_string(e)}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  # 切活动页(builder 之后改这页)。
  defp pages_set_active(ws, sid, id) do
    case Ezagent.PluginLoom.Pages.set_active(ws, sid, id, live_active_source(ws, sid)) do
      {:ok, data} -> %{ok: true, active: data["active"]}
      {:error, e} -> %{ok: false, error: to_string(e)}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  # 回存某页源码(前端渲染后 / 切页前)。
  defp pages_put_source(ws, sid, id, source) do
    case Ezagent.PluginLoom.Pages.put_source(ws, sid, to_string(id), source || %{}) do
      {:ok, _} -> %{ok: true}
      {:error, e} -> %{ok: false, error: to_string(e)}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  # 发布页:按 cookie 身份核对 `?role=<key>`。角色不存在 → exists:false(前端不出按钮);
  # 存在则三态:未登录 / 已登录+通过(带 label/effect/view/url)/ 已登录+无权限。
  # 临时用户升级:正式账号接管会话。须已登录(cookie 身份)。
  defp upgrade_temp(conn, ws, sid) do
    case caller_entity(conn) do
      {:ok, %URI{scheme: "entity", path: "/user/" <> _} = target} ->
        suri = session_uri(ws, sid)
        # 1) 会话所有权转移:正式账号成为成员(force-join,system caps)。
        _ = ensure_joined(suri, target)

        # 2) 对话历史迁移:当前 Salesperson 对话快照归到账号名下(底层消息表不动)。
        convo = salesperson_conversation(ws, sid)
        _ = Ezagent.PluginLoom.OwnedSessions.claim(URI.to_string(target), ws, sid, convo)

        %{ok: true, entity_uri: URI.to_string(target), migrated_turns: length(convo)}

      _ ->
        %{ok: false, error: "not logged in"}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  # 当前登录身份在该 session 符合的全部角色 + 是否配了门控(给登录按钮判断用)。
  defp my_roles(conn, ws, sid) do
    who = caller_entity_str(conn)
    roles = Ezagent.PluginLoom.RoleConfig.roles_for(ws, sid, who)

    base = %{
      ok: true,
      logged_in: who != nil,
      configured: Ezagent.PluginLoom.RoleConfig.gated?(ws, sid),
      roles:
        Enum.map(roles, fn r ->
          %{
            key: Map.get(r, "key", ""),
            label: Map.get(r, "label", ""),
            effect: Map.get(r, "effect", "navigate"),
            view: Map.get(r, "view", ""),
            url: Map.get(r, "url", ""),
            page: Map.get(r, "page", "")
          }
        end)
    }

    if who, do: Map.put(base, :entity_uri, who), else: base
  rescue
    e -> %{ok: false, error: Exception.message(e), roles: [], logged_in: false, configured: false}
  end

  defp role_check(conn, ws, sid, role) do
    who = caller_entity_str(conn)
    {granted, role_map} = Ezagent.PluginLoom.RoleConfig.check(ws, sid, role, who)

    base = %{
      ok: true,
      exists: role_map != nil,
      role: role,
      logged_in: who != nil,
      granted: granted
    }

    base =
      case who do
        nil -> base
        w -> Map.put(base, :entity_uri, w)
      end

    case role_map do
      %{} = m ->
        Map.merge(base, %{
          label: Map.get(m, "label", ""),
          effect: Map.get(m, "effect", "navigate"),
          view: Map.get(m, "view", ""),
          url: Map.get(m, "url", ""),
          page: Map.get(m, "page", "")
        })

      _ ->
        Map.merge(base, %{label: "", effect: "navigate", view: "", url: "", page: ""})
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  # --- 2026-06-15 接线员(operator)多 session helpers ---

  # 从鉴权 cookie 解析当前登录 entity URI(同 whoami / LiveAuth 的 key)。
  defp caller_entity(conn) do
    conn = Plug.Conn.fetch_session(conn)

    case Plug.Conn.get_session(conn, "current_entity_uri") do
      uri when is_binary(uri) and uri != "" -> {:ok, Ezagent.URI.new!(uri)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # 列出当前登录 entity **作为 chat 成员**的所有 session(跨 workspace)。
  defp list_my_sessions(conn) do
    case caller_entity(conn) do
      {:ok, entity_uri} ->
        sessions =
          EzagentDomainInstanceMessage.list_sessions()
          |> Enum.filter(&member_of?(&1, entity_uri))
          |> Enum.map(&session_summary/1)
          |> Enum.sort_by(& &1.title)

        %{ok: true, logged_in: true, entity_uri: URI.to_string(entity_uri), sessions: sessions}

      :error ->
        %{ok: true, logged_in: false, sessions: []}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e), sessions: []}
  end

  # entity 是否是 session 的 chat 成员。
  defp member_of?(%URI{} = session_uri, %URI{} = entity_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{members: members}} when is_map(members) ->
        target = URI.to_string(entity_uri)
        Enum.any?(Map.keys(members), fn k -> member_uri_str(k) == target end)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp member_of?(_, _), do: false

  defp member_uri_str(%URI{} = u), do: URI.to_string(u)
  defp member_uri_str(s) when is_binary(s), do: s
  defp member_uri_str(o), do: inspect(o)

  defp session_summary(%URI{} = session_uri) do
    {ws, sid} = sess_ws_sid(session_uri)

    last_text =
      case last_session_message(session_uri) do
        %Ezagent.Message{body: body} -> body |> body_text() |> String.slice(0, 80)
        _ -> ""
      end

    # `uri` is what the SPA parses to navigate to a cohort session, so emit it in
    # the SPA's stitch layout; `last_text` above already used the canonical URI.
    %{uri: fe_session_uri(ws, sid), ws: ws, sid: sid, title: sid, last_text: last_text}
  end

  defp last_session_message(session_uri) do
    session_uri |> Ezagent.MessageStore.recent_in_session(1) |> List.first()
  rescue
    _ -> nil
  end

  # workspace-first `session://<ws>/<class>/<sid>` → {ws, sid}(ws = host,sid = name 段)。
  defp sess_ws_sid(%URI{host: ws, path: path})
       when is_binary(ws) and ws != "" and is_binary(path) do
    case path |> String.trim_leading("/") |> String.split("/") do
      [_class, sid | _] -> {ws, sid}
      _ -> {ws, ""}
    end
  end

  defp sess_ws_sid(_), do: {"", ""}

  # 以登录 entity 的身份往一个 session 发消息(成员身份门控)。无 @ → 默认只到
  # session 的 User 成员(mention-gated),即「人对人群聊」;同时 sender host=user →
  # 会以弹幕飘在该 session 的预览页。要触发编排器/worker 需在文本里显式 @。
  # 接线员同伴集:本会话(ws,sid)所属发布版本衍生的所有会话(不含自己)。须已登录。
  defp operator_sessions(conn, ws, sid) do
    case caller_entity(conn) do
      {:ok, %URI{} = who} ->
        sessions =
          Ezagent.PluginLoom.Lineage.cohort(ws, sid)
          |> Enum.flat_map(fn ref ->
            case safe_session_uri(ref) do
              %URI{} = u -> [session_summary(u)]
              _ -> []
            end
          end)
          |> Enum.sort_by(& &1.title)

        %{ok: true, logged_in: true, entity_uri: URI.to_string(who), sessions: sessions}

      :error ->
        %{ok: true, logged_in: false, sessions: []}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e), sessions: []}
  end

  # 接线员发消息(scoped):只能发给本版本同伴集里的会话。接线员若非目标会话成员 → 先 join。
  defp operator_send_scoped(conn, ws, sid) do
    body = conn.body_params || %{}
    uri_str = body |> Map.get("uri", "") |> to_string()
    text = body |> Map.get("text", "") |> to_string() |> String.trim()

    with {:ok, entity_uri} <- caller_entity(conn),
         %URI{scheme: "session"} = target <- parse_fe_session_uri(uri_str),
         true <- text != "",
         {tws, tsid} <- sess_ws_sid(target),
         true <- Ezagent.PluginLoom.Lineage.in_cohort?(ws, sid, tws, tsid) do
      # 接线员可能不是目标会话成员 → 先 force-join,再以登录身份发(message 飘进该会话)。
      _ = ensure_joined(target, entity_uri)
      msg = Ezagent.Message.new(entity_uri, %{text: text, attachments: []}, mentions: [])

      inv = %Ezagent.Invocation{
        target: Ezagent.URI.with_action(target, :session, :send),
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: entity_uri,
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
      :error -> %{ok: false, error: "not_logged_in"}
      false -> %{ok: false, error: "not_in_cohort_or_empty"}
      _ -> %{ok: false, error: "bad_request"}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp operator_send(conn) do
    body = conn.body_params || %{}
    uri_str = body |> Map.get("uri", "") |> to_string()
    text = body |> Map.get("text", "") |> to_string() |> String.trim()

    with {:ok, entity_uri} <- caller_entity(conn),
         %URI{scheme: "session"} = session_uri <- parse_fe_session_uri(uri_str),
         true <- text != "",
         true <- member_of?(session_uri, entity_uri) do
      msg = Ezagent.Message.new(entity_uri, %{text: text, attachments: []}, mentions: [])

      inv = %Ezagent.Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :send),
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: entity_uri,
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
      :error -> %{ok: false, error: "not_logged_in"}
      false -> %{ok: false, error: "not_a_member_or_empty"}
      _ -> %{ok: false, error: "bad_request"}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp safe_session_uri(s) when is_binary(s) and s != "" do
    case Ezagent.URI.new!(s) do
      %URI{scheme: "session"} = u -> u
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_session_uri(_), do: nil

  # 前端传来的 caps 直通(限制条数,防 prompt 过长)。只保留有 id 的对象。
  defp normalize_caps(caps) when is_list(caps) do
    caps |> Enum.filter(&(is_map(&1) and Map.get(&1, "id") not in [nil, ""])) |> Enum.take(40)
  end

  defp normalize_caps(_), do: []

  # --- Salesperson / AiSpot → loomsalesperson worker(2026-06-10 重构)-------------
  # preview 侧 AI 不再直连 DeepSeek。每次请求包成一条 `@loomsalesperson_<sid>` 消息派进
  # session,由 salesperson worker(DeepSeek)处理,回 `salesperson_reply` 帧经 SSE 流回前端。

  defp aispot_visible(""), do: "✨ AI 解读"
  defp aispot_visible(feature), do: "✨ " <> feature

  # 幂等 spawn + join loomsalesperson worker(老会话兜底)。失败不阻断(派发仍会进行,
  # 极端情况落 DLQ,但正常路径已就位)。
  defp ensure_salesperson_worker(%URI{} = suri, %URI{} = salesperson_uri) do
    _ = Ezagent.SpawnRegistry.spawn(salesperson_uri)
    _ = ensure_joined(suri, salesperson_uri)

    # 2026-06-12 — 同时确保 4 个 Salesperson 子 worker 在场。老会话(在 ensure_team 加
    # 子 worker 之前创建的 zuatu / tudou 等)靠这里按需 spawn + join(幂等),
    # 否则编排器 fan-out 派给不存在的子 worker → 无 deliverable → 超时降级。
    with %URI{host: ws, path: path} when is_binary(ws) and ws != "" <- suri,
         [_class, sid | _] <- path |> to_string() |> String.trim_leading("/") |> String.split("/") do
      Enum.each(EzagentPluginLoom.SalespersonExperts.role_keys(), fn role ->
        sub = Ezagent.URI.new!("entity://#{ws}/agent/loomsalespersonsub_#{sid}_#{role}")
        _ = Ezagent.SpawnRegistry.spawn(sub)
        _ = ensure_joined(suri, sub)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  # 派 @loomsalesperson 消息(异步)。结构化负载放 body 的 `:salesperson` 键;visible_text 是
  # admin/session 可见的那句。返回 `%{ok, id}`(id=消息 id,前端据此关联回帧)。
  defp dispatch_to_salesperson(conn, ws, sid, payload, visible_text) do
    suri = session_uri(ws, sid)
    salesperson_uri = Ezagent.URI.new!("entity://#{ws}/agent/loomsalesperson_#{sid}")

    # 幂等保证 salesperson worker 在场:老会话(zuatu / 发布物)boot 时不一定重跑 ensure_team,
    # 所以这里按需 spawn + join(已在则短路)。新会话由 Team.ensure_team 装配。
    _ = ensure_salesperson_worker(suri, salesperson_uri)

    with {:ok, user_uri} <- consumer_sender(conn, ws, sid),
         :ok <- ensure_joined(suri, user_uri) do
      # 2026-06-12 — 与 `send_to_session`/`parse_mentions` 的编排器路径一致:在
      # 可见文本前缀 `@loomsalesperson_<sid>`,让 admin/session 视图肉眼看得到这条确实
      # @ 了 salesperson(此前只塞了 `mentions` 结构化字段,人眼看不到,跟 @编排器 不一致)。
      # 路由仍走 `mentions`(不依赖文本解析),前缀只是给人眼看。preview 侧 Salesperson
      # 气泡用前端本地 echo,不受此前缀影响。
      visible_with_mention = "@loomsalesperson_#{sid} " <> visible_text

      msg =
        Ezagent.Message.new(
          user_uri,
          %{text: visible_with_mention, attachments: [], salesperson: payload},
          mentions: [salesperson_uri]
        )

      inv = %Ezagent.Invocation{
        target: Ezagent.URI.with_action(suri, :session, :send),
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

  # GET /salesperson:从 session 历史重建 Salesperson 聊天线程(取代旧 SalespersonChat)。只取
  # mode=salesperson 的用户消息(@loomsalesperson 发起)+ loomsalesperson 回的 salesperson_reply。
  # AiSpot(mode=aispot)不进聊天面板。
  defp salesperson_conversation(ws, sid) do
    salesperson_name = "loomsalesperson_#{sid}"

    session_uri(ws, sid)
    |> Ezagent.MessageStore.recent_in_session(80)
    |> Enum.reverse()
    |> Enum.flat_map(&salesperson_turn(&1, salesperson_name))
  rescue
    _ -> []
  end

  defp salesperson_turn(%Ezagent.Message{sender: sender, body: body}, salesperson_name) do
    cond do
      # assistant:loomsalesperson 回的消息。body 是纯文本;mode/drive 在 salesperson_reply 字段。
      String.contains?(to_string(sender), "/" <> salesperson_name) ->
        case salesperson_meta_of(body) do
          %{} = meta ->
            if to_string(meta["mode"] || meta[:mode] || "salesperson") == "salesperson",
              do: [
                %{
                  "role" => "assistant",
                  "text" => body_text(body),
                  "drive" => meta["drive"] || meta[:drive]
                }
              ],
              else: []

          _ ->
            []
        end

      # user:@loomsalesperson 发起的 salesperson 聊天(body.salesperson.mode == "salesperson")
      true ->
        payload = (is_map(body) && (body["salesperson"] || body[:salesperson])) || nil

        case payload do
          %{} = p ->
            if to_string(p["mode"] || p[:mode] || "salesperson") == "salesperson",
              do: [%{"role" => "user", "text" => body_text(body)}],
              else: []

          _ ->
            []
        end
    end
  end

  defp salesperson_turn(_, _), do: []

  # 从当前 preview 会话冻结快照副本(页面取自 orchestrator 的 loom_source,ops 取自
  # user_schema,**Salesperson 对话取自 SalespersonChat**)。三者都是**副本**:之后 live 会话继续
  # 增强/对话,这份快照不变,被分享者看到的是冻结时刻的状态。
  defp create_snapshot(ws, sid) do
    case read_orchestrator_snapshot(ws, sid) do
      {:ok, %{"loom_source" => page} = orch} ->
        token = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

        Ezagent.PluginLoom.Snapshots.put(token, %{
          "ws" => ws,
          "page" => page,
          # 2026-06-10 — Salesperson 样式随快照冻结,fork 出的会话据此 seed。
          "salesperson_config" => Map.get(orch, "salesperson_config"),
          "danmaku_config" => Map.get(orch, "danmaku_config"),
          "ops" => Ezagent.PluginLoom.UserSchema.get(ws, sid),
          # 2026-06-10 — Salesperson 对话现在存在 session 消息里(不再是 SalespersonChat),
          # 从 session 历史重建,否则快照冻结的是空对话。
          "conversation" => salesperson_conversation(ws, sid),
          "knowledge" => Ezagent.PluginLoom.Knowledge.get(ws, sid),
          # 多页随快照冻结(活动页源码用本次 snapshot 的 page 覆盖)→ fork / 只读 ?page= 用。
          "pages" => Ezagent.PluginLoom.Pages.bundle(ws, sid, page),
          # 角色门控配置随快照冻结 → fork 出的会话 seed 它(创建者 + 各角色账号一起带过去)。
          "roles" => Ezagent.PluginLoom.RoleConfig.get(ws, sid),
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
  # 从发布模板衍生一个全套**可编辑**会话(no_builder=false → 带 builder)。
  defp derive_editable(token, name) do
    name = String.trim(name)

    if Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) do
      case Ezagent.PluginLoom.SavedClasses.find_by_token(token) do
        {:ok, class_name, ws} -> do_derive(token, class_name, ws, name)
        _ -> %{ok: false, error: "找不到这个发布物 token"}
      end
    else
      %{ok: false, error: "名字只能含字母 / 数字 / _ / -,且非空"}
    end
  rescue
    e -> %{ok: false, error: Exception.message(e)}
  end

  defp do_derive(token, class_name, ws, name) do
    suri = Ezagent.URI.new!("session://#{ws}/loom/#{name}")

    cond do
      session_alive?(suri) ->
        %{ok: false, error: "会话「#{name}」已存在,换个名字"}

      true ->
        case Ezagent.PluginLoom.SavedClasses.saved_state_for_token(token) do
          %{} = saved_state ->
            workspace_uri = Ezagent.URI.new!("workspace://#{ws}")

            tmpl = %{
              "class" => "session.loom",
              "session_name" => name,
              # **可编辑**:带 builder(区别于发布物冻结消费会话的 no_builder=true)。
              "no_builder" => false,
              "saved_state" => saved_state
            }

            case Ezagent.PluginLoom.Template.LoomSession.instantiate(
                   "session.loom",
                   tmpl,
                   workspace_uri
                 ) do
              {:ok, [_session_uri | _]} ->
                # 多页 / 角色 / 知识库随模板带过去。
                _ =
                  Ezagent.PluginLoom.Pages.seed(
                    ws,
                    name,
                    Ezagent.PluginLoom.SavedClasses.pages_for_token(token)
                  )

                _ =
                  Ezagent.PluginLoom.RoleConfig.seed(
                    ws,
                    name,
                    Ezagent.PluginLoom.SavedClasses.roles_for_token(token)
                  )

                _ =
                  Ezagent.PluginLoom.Knowledge.put(
                    ws,
                    name,
                    Ezagent.PluginLoom.SavedClasses.knowledge_for_token(token)
                  )

                # 谱系:挂在该模板下(forked_from)。
                _ = Ezagent.PluginLoom.Lineage.record_derive(ws, name, class_name)

                %{ok: true, ws: ws, sid: name, link: "/loom/#{ws}/#{name}"}

              {:error, reason} ->
                %{ok: false, error: inspect(reason)}

              other ->
                %{ok: false, error: inspect({:unexpected, other})}
            end

          _ ->
            %{ok: false, error: "这个发布物没有 saved_state,无法衍生"}
        end
    end
  end

  defp session_alive?(%URI{} = suri) do
    match?({:ok, _}, Ezagent.KindRegistry.lookup(suri))
  rescue
    _ -> false
  end

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
           "no_builder" => true,
           "saved_state" => %{
             "orchestrator" =>
               %{"loom_source" => page}
               |> put_if(snap, "salesperson_config")
               |> put_if(snap, "danmaku_config")
           }
         },
         {:ok, [session_uri | _]} <-
           Ezagent.PluginLoom.Template.LoomSession.instantiate(
             "session.loom",
             tmpl,
             workspace_uri
           ),
         {:ok, user_uri} <- ensure_consumer_anon(ws, sid),
         :ok <- ensure_joined(session_uri, user_uri) do
      # 复制快照 ops + Salesperson 对话 + 知识库进新 session(forker 之后改不影响快照)。
      _ = Ezagent.PluginLoom.UserSchema.replace(ws, sid, Map.get(snap, "ops", []))
      _ = Ezagent.PluginLoom.SalespersonChat.replace(ws, sid, Map.get(snap, "conversation", []))
      _ = Ezagent.PluginLoom.Knowledge.put(ws, sid, Map.get(snap, "knowledge", ""))
      # 多页随快照 seed 进 fork 出的会话。
      _ = Ezagent.PluginLoom.Pages.seed(ws, sid, Map.get(snap, "pages", %{}))

      # 角色门控随快照 seed 进 fork 出的会话(创建者 + 各角色账号),fork 后该 session 自带角色门控。
      _ = Ezagent.PluginLoom.RoleConfig.seed(ws, sid, Map.get(snap, "roles", %{}))

      # 谱系:这个 fork 从快照的 origin_sid(被分享的消费 session)衍生 → 记一条 forked_from。
      _ = Ezagent.PluginLoom.Lineage.record_fork(ws, sid, Map.get(snap, "origin_sid"))

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

  # Copy `key` from `src` into `map` only when present + non-empty (keeps the
  # saved_state.orchestrator map lean — absent salesperson_config stays absent).
  defp put_if(map, src, key) do
    case Map.get(src, key) do
      v when is_map(v) and map_size(v) > 0 -> Map.put(map, key, v)
      _ -> map
    end
  end

  defp read_full_session_snapshot(ws, sid) do
    case read_orchestrator_snapshot(ws, sid) do
      {:ok, orch_snapshot} ->
        workers = read_workers_snapshot(ws, sid)
        v0 = read_builder_snapshot(ws, sid)

        {:ok,
         %{
           "orchestrator" => orch_snapshot,
           "workers" => workers,
           "builder" => v0
         }}

      {:error, _} = err ->
        err
    end
  end

  # 从 session 的 chat.members 里扫所有 loomworker_<sid>_<theme> URI;
  # 对每个 worker 读 :loom_worker slice,出 {theme, system_prompt, role} 三件套。
  # 找不到 session / slice 缺数据 → 空列表(降级到 Team 默认)。
  defp read_workers_snapshot(ws, sid) do
    session_uri = Ezagent.URI.new!("session://#{ws}/loom/#{sid}")

    case Ezagent.Kind.get_slice(session_uri, :session) do
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
  defp read_builder_snapshot(_ws, _sid), do: %{}

  # 抓 orchestrator slice 的"用户可感知"字段(persona + loom_source);
  # `pending` / `count` / `last_error` 是 runtime 易逝态,不进快照。
  # workers 也不抓 —— 当前 LoomWorker 用 init 默认值,LoomBuilderWorker 无状态。
  defp read_orchestrator_snapshot(ws, sid) do
    orch_uri = Ezagent.URI.new!("entity://#{ws}/agent/loomorch_#{sid}")

    # 2026-06-11 — 幂等补 spawn orchestrator(老会话兜底)。发布/消费会话(pub_*)是按需
    # mint 的临时会话,boot 时不重跑 Team.ensure_team,server 重启后 orchestrator 进程没了
    # → get_slice 直接 :not_found,快照/存模板失败。这里像 ensure_salesperson_worker 一样按需
    # 复活:有持久化快照就 rehydrate 回 loom_source(已在则短路)。失败不阻断,交给下面读。
    _ =
      try do
        Ezagent.SpawnRegistry.spawn(orch_uri)
      rescue
        _ -> :ok
      end

    # slice(orchestrator 缓存的源 + persona + salesperson 样式)。可能滞后 / 为空 / 退化成
    # 默认页(老会话重启后被默认 seed),所以下面**优先用最新 page_update 消息**。
    {slice_files, slice_cfg, slice_danmaku, persona} =
      case Ezagent.Kind.get_slice(orch_uri, :loom_orchestrator) do
        {:ok, slice} when is_map(slice) ->
          raw = slice[:loom_source] || slice["loom_source"]
          files = EzagentPluginLoom.Prompts.normalize_source(raw)
          sf = if raw in [nil, "", %{}] or map_size(files) == 0, do: nil, else: files

          {sf, slice[:salesperson_config] || slice["salesperson_config"],
           slice[:danmaku_config] || slice["danmaku_config"],
           slice[:persona] || slice["persona"] || "visitor"}

        _ ->
          {nil, nil, nil, "visitor"}
      end

    # 2026-06-11 — 发布/快照冻结的应是**用户此刻看到的页面** = 编辑器从最新 page_update
    # 消息渲染的那一份。slice 只是 orchestrator 的缓存,可能滞后(直接改库 / 删快照后
    # 退化成默认页),故**优先消息,slice 兜底**。消息没带 salespersonConfig 时用 slice 的。
    {msg_files, msg_cfg} =
      case latest_page_update(ws, sid) do
        {f, c} -> {f, c}
        _ -> {nil, nil}
      end

    files = msg_files || slice_files
    cfg = msg_cfg || slice_cfg

    if is_map(files) and map_size(files) > 0 do
      {:ok, build_orch_snapshot(persona, files, cfg, slice_danmaku)}
    else
      {:error, :no_source_in_orchestrator}
    end
  end

  # publish/snapshot 用的 orchestrator 快照 shape(persona + loom_source [+ salesperson_config] [+ danmaku_config])。
  defp build_orch_snapshot(persona, files, salesperson_cfg, danmaku_cfg \\ nil) do
    base = %{"persona" => to_string(persona || "visitor"), "loom_source" => files}

    base =
      if is_map(salesperson_cfg) and map_size(salesperson_cfg) > 0,
        do: Map.put(base, "salesperson_config", salesperson_cfg),
        else: base

    if is_map(danmaku_cfg) and map_size(danmaku_cfg) > 0,
      do: Map.put(base, "danmaku_config", danmaku_cfg),
      else: base
  end

  # 从会话历史里取最新一条 page_update 的 {files, salespersonConfig}(recent_in_session 按
  # inserted_at DESC,故第一条命中即最新)。无则 nil。
  defp latest_page_update(ws, sid) do
    session_uri(ws, sid)
    |> Ezagent.MessageStore.recent_in_session(200)
    |> Enum.find_value(&parse_page_update_msg/1)
  rescue
    _ -> nil
  end

  defp parse_page_update_msg(%Ezagent.Message{body: body}) do
    text =
      case body do
        %{text: t} when is_binary(t) -> t
        %{"text" => t} when is_binary(t) -> t
        _ -> ""
      end

    with [_full, inner] <- Regex.run(~r/<span\s+type="page_update"\s*>([\s\S]*)<\/span>/, text),
         {:ok, decoded} <- Jason.decode(String.trim(inner)) do
      files = EzagentPluginLoom.Prompts.normalize_source(decoded["files"] || decoded["source"])

      if is_map(files) and map_size(files) > 0,
        do: {files, decoded["salespersonConfig"]},
        else: nil
    else
      _ -> nil
    end
  end

  defp parse_page_update_msg(_), do: nil

  # 2026-06-17 — page_update 里 builder 打的「这条改的是哪一页」(页 id)。无 → nil(老消息)。
  defp page_update_msg_page(%Ezagent.Message{body: body}) do
    text =
      case body do
        %{text: t} when is_binary(t) -> t
        %{"text" => t} when is_binary(t) -> t
        _ -> ""
      end

    with [_full, inner] <- Regex.run(~r/<span\s+type="page_update"\s*>([\s\S]*)<\/span>/, text),
         {:ok, %{"page" => p}} when is_binary(p) and p != "" <- Jason.decode(String.trim(inner)) do
      p
    else
      _ -> nil
    end
  end

  defp page_update_msg_page(_), do: nil

  # page_update 里 builder 给这次编辑的说明(无 → nil)。
  defp page_update_msg_summary(%Ezagent.Message{body: body}) do
    text =
      case body do
        %{text: t} when is_binary(t) -> t
        %{"text" => t} when is_binary(t) -> t
        _ -> ""
      end

    with [_full, inner] <- Regex.run(~r/<span\s+type="page_update"\s*>([\s\S]*)<\/span>/, text),
         {:ok, %{"summary" => s}} when is_binary(s) and s != "" <-
           Jason.decode(String.trim(inner)) do
      s
    else
      _ -> nil
    end
  end

  defp page_update_msg_summary(_), do: nil

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
      :ok ->
        # 谱系:模板被删 → 忘掉它这个节点(子节点变孤儿,树仍可渲染)。
        _ = Ezagent.PluginLoom.Lineage.forget(name)
        %{ok: true}

      {:error, reason} ->
        %{ok: false, error: inspect(reason)}
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

  # 2026-06-01 / Plan B(loom-port)— Class 级 spawn:`class_name` 是 `session.<saved>`
  # (存模板备份)。改成数据驱动实例化(不再经 TemplateRegistry 查合成模块)。
  defp do_spawn_from_template(ws, class_name, new_session_name) do
    with :ok <- refuse_if_session_exists(ws, new_session_name),
         workspace_uri = Ezagent.URI.new!("workspace://#{ws}"),
         {:ok, [session_uri | _]} <-
           Ezagent.PluginLoom.SavedClasses.instantiate_from_data(
             class_name,
             new_session_name,
             workspace_uri
           ) do
      # Hand the SPA a stitch-layout URI so its parser navigates to the right ws.
      {sws, ssid} = sess_ws_sid(session_uri)
      %{ok: true, session_uri: fe_session_uri(sws, ssid)}
    else
      {:error, :not_found} -> %{ok: false, error: "class_not_found"}
      {:error, reason} -> %{ok: false, error: inspect(reason)}
      other -> %{ok: false, error: inspect({:unexpected, other})}
    end
  end

  defp refuse_if_session_exists(ws, name) do
    uri = Ezagent.URI.new!("session://#{ws}/loom/#{name}")

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} -> {:error, :session_already_exists}
      _ -> :ok
    end
  end
end
