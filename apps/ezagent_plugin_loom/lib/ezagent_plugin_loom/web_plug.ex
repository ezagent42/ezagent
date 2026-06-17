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
  alias EzagentPluginLoom.{Fork, Intent, Knowledge, Materials, Stitch, Tool, FetchProxy, UserSchema}

  @gateway_uri "system://loom-customer-gateway"

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
         {:ok, result} <-
           Stitch.reply(text, page: conn.body_params["page"], knowledge: Knowledge.get(session_uri)) do
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

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- helpers --------------------------------------------------------------

  defp uris(ws, sid) do
    {:ok, Ezagent.URI.session(ws, :loom, sid), Ezagent.URI.workspace(ws)}
  rescue
    _ -> :error
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
