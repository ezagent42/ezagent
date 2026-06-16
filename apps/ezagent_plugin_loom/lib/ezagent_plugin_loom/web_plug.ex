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

  @gateway_uri "system://loom-customer-gateway"

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
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
      json(conn, 200, %{
        ok: true,
        messages: render_messages(snapshot.messages),
        page: snapshot.page
      })
    else
      {:error, :unauthorized} -> json(conn, 401, %{ok: false, error: "unauthorized"})
      _ -> json(conn, 400, %{ok: false, error: "bad_request"})
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
