defmodule EzagentWeb.CustomerChatController do
  @moduledoc """
  Phase 2.3 (rebased from EXP-C3) — Web customer chat via HTTP POST + SSE.

  Single endpoint: `POST /api/customer/:workspace/chat`

  Request JSON:
      {"customer_id": "alice", "text": "warranty?", "conv_id": "c1"}

  Path semantics:
    - `:workspace` is the tenant (e.g. `acme`). Validated against
      `Ezagent.Workspace.Store`; unknown workspaces yield HTTP 404.
      NEVER hardcoded in this controller — that would violate the
      migration design constraint
      (`docs/ezagent-migration/migration-design-constraints.md` §1).

  Response: Server-Sent Events stream (`text/event-stream`).

  Session model (Phase 1+2 verdict):
    `session://default/<workspace>/<conv_id>` — one session per
    conversation. Concurrent customers with distinct `conv_id`s land
    on isolated sessions, with no PubSub cross-pollination. Sessions
    are auto-created on first sight via `EzagentDomainChat.create_session/3`
    (which returns the 3-tuple `{:ok, uri, meta}` post-ezagent#408).

  All session/cc/dispatch logic is delegated to the shared
  `EzagentPluginCustomerChat.Bootstrap` module (the customer
  LiveView shares the same code path). This controller owns only the
  HTTP+SSE transport.

  Lifecycle per request:
    1. Validate `:workspace` exists (`Bootstrap.validate_workspace/1`);
       mint customer entity URI `entity://user/<workspace>/customer_<id>`.
    2. Compute / generate `conv_id`, derive session URI, ensure session
       exists (`Bootstrap.ensure_session/2`, idempotent).
    3. Subscribe to the session events topic
       `esr:session:<session_uri>:events`.
    4. Open the SSE stream. Call `Bootstrap.ensure_cc_for_conv/3` to
       guarantee the cc agent exists and its EagerBridge is bound
       (idempotent; first request for a conv_id pays the ~5-10s
       spawn+handshake), then dispatch `chat.send` via
       `Bootstrap.dispatch_chat_send/2` (admin bootstrap caps).
    5. Loop (until timeout / terminal reply / connection close):
       receive `{:chat_message, _, msg}` and `chunk` it back to the
       client as an SSE event. Skip the customer's own echo
       (sender == customer_uri) so the client only sees agent traffic.

  Stateless on the server: no per-request GenServer, no socket
  persistence — just a process inbox tied to the connection.

  Terminates on:
    - cc agent reply observed (marker: `sender == agent_uri`).
    - Hard timeout (`@reply_timeout_ms`).
    - Client disconnect (`chunk/2` returns `{:error, :closed}`).

  Session/cc/builder logic is delegated to
  `EzagentPluginCustomerChat.Bootstrap` so the SSE controller
  and the upcoming customer LiveView share one code path.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias EzagentPluginCustomerChat.Bootstrap

  @reply_timeout_ms 120_000

  def chat(conn, %{"customer_id" => cust_id, "text" => text} = params)
      when is_binary(cust_id) and is_binary(text) do
    workspace = Map.get(conn.path_params, "workspace") || Map.get(params, "workspace")

    case Bootstrap.validate_workspace(workspace) do
      :ok ->
        run_chat(conn, workspace, cust_id, text, params)

      {:error, reason} ->
        conn
        |> put_status(404)
        |> json(%{error: reason, workspace: workspace})
    end
  end

  def chat(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing required fields", required: ["customer_id", "text"]})
  end

  defp run_chat(conn, workspace, cust_id, text, params) do
    conv_id =
      case Map.get(params, "conv_id") do
        nil -> Bootstrap.generate_conv_id()
        "" -> Bootstrap.generate_conv_id()
        id when is_binary(id) -> id
      end

    customer_uri = Bootstrap.customer_uri_for(workspace, cust_id)
    session_uri = Bootstrap.session_uri_for(workspace, conv_id)
    session_uri_str = URI.to_string(session_uri)
    topic = "esr:session:#{session_uri_str}:events"

    :ok = Bootstrap.ensure_session(workspace, conv_id)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    case Bootstrap.ensure_cc_for_conv(workspace, conv_id, session_uri) do
      {:ok, cc_agent_uri} ->
        cc_agent_uri_str = URI.to_string(cc_agent_uri)
        customer_msg = Bootstrap.customer_message(customer_uri, text, cc_agent_uri)

        {:ok, conn} =
          sse_chunk(conn, "open", %{
            workspace: workspace,
            conv_id: conv_id,
            session_uri: session_uri_str,
            customer_uri: URI.to_string(customer_uri),
            agent_uri: cc_agent_uri_str,
            sent_msg_id: customer_msg.id
          })

        Bootstrap.dispatch_chat_send(session_uri, customer_msg)

        conn =
          stream_loop(conn,
            agent_uri_str: cc_agent_uri_str,
            customer_uri_str: URI.to_string(customer_uri),
            deadline: System.monotonic_time(:millisecond) + @reply_timeout_ms
          )

        Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic)
        conn

      {:error, reason} ->
        {:ok, conn} = sse_chunk(conn, "error", %{reason: "agent_setup_failed", detail: inspect(reason)})
        {:ok, conn} = sse_chunk(conn, "close", %{reason: "error"})
        Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic)
        conn
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # SSE receive loop

  defp stream_loop(conn, opts) do
    deadline = Keyword.fetch!(opts, :deadline)
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)
    agent_uri_str = Keyword.fetch!(opts, :agent_uri_str)
    customer_uri_str = Keyword.fetch!(opts, :customer_uri_str)

    receive do
      {:chat_message, _session_uri, %Ezagent.Message{sender: sender, body: body} = msg} ->
        sender_str = URI.to_string(sender)

        cond do
          sender_str == customer_uri_str ->
            # Don't echo the customer's own message back. (chat.send's
            # broadcast happens before our send_chunked completes; we
            # could see it here too.)
            stream_loop(conn, opts)

          true ->
            payload = %{
              msg_id: msg.id,
              sender: sender_str,
              text: Map.get(body || %{}, :text) || Map.get(body || %{}, "text"),
              terminal: sender_str == agent_uri_str
            }

            case sse_chunk(conn, "message", payload) do
              {:ok, conn} ->
                if sender_str == agent_uri_str do
                  {:ok, conn} = sse_chunk(conn, "close", %{reason: "terminal"})
                  conn
                else
                  stream_loop(conn, opts)
                end

              {:error, :closed} ->
                conn
            end
        end

      _other ->
        stream_loop(conn, opts)
    after
      timeout ->
        case sse_chunk(conn, "close", %{reason: "timeout", timeout_ms: @reply_timeout_ms}) do
          {:ok, conn} -> conn
          {:error, :closed} -> conn
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # SSE framing

  defp sse_chunk(conn, event, data) when is_binary(event) and is_map(data) do
    payload = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
    Plug.Conn.chunk(conn, payload)
  end
end
