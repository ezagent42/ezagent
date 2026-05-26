defmodule EzagentWeb.CustomerChatController do
  @moduledoc """
  EXP-C3 — Web customer chat via HTTP POST + SSE.

  Single endpoint: `POST /api/customer/:workspace/chat`

  Request JSON:
      {"customer_id": "alice", "text": "warranty?", "conv_id": "c1"}

  Response: Server-Sent Events stream (`text/event-stream`).

  Lifecycle per request:
    1. Build a synthetic customer entity URI
       `entity://user/<workspace>/customer_<customer_id>`.
    2. Subscribe to the session events topic
       `esr:session:<session_uri>:events` (which session is keyed off
       `conv_id` — see `session_uri_for/2`).
    3. Open the SSE stream and dispatch `chat.send` with the customer
       message as the bootstrap-cap'd caller.
    4. Fire a synthetic-reply Task (500ms) that broadcasts a
       `{:chat_message, session_uri, %Ezagent.Message{}}` tuple back into
       the session topic. (The cc agent bridge is not exercised here —
       see Phase 0 FINDINGS.md.)
    5. Loop forever (until timeout / terminal reply / connection close):
       receive `{:chat_message, _, msg}` and `chunk` it back to the
       client as an SSE event. Skip the customer's own echo (sender ==
       customer_uri) so the client only sees agent-side traffic.

  Stateless on the server: no per-request GenServer, no socket
  persistence — just a process inbox tied to the connection.

  Terminates on:
    - Synthetic agent reply observed (marker: `sender == agent_uri`).
    - Hard timeout (`@reply_timeout_ms`, default 30s).
    - Client disconnect (`chunk/2` returns `{:error, :closed}`).
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  @reply_timeout_ms 30_000
  # Agent URI used by the synthetic-reply path. In a real deployment this
  # would be resolved from session membership; here it is a fixture so
  # the SSE stream knows what "terminal" looks like.
  @agent_uri_str "entity://user/__synthetic__/echo_agent"

  def chat(conn, %{"customer_id" => cust_id, "text" => text} = params)
      when is_binary(cust_id) and is_binary(text) do
    workspace = Map.get(conn.path_params, "workspace") || Map.get(params, "workspace", "default")
    conv_id = Map.get(params, "conv_id", "default")

    customer_uri = URI.parse("entity://user/#{workspace}/customer_#{cust_id}")
    session_uri = session_uri_for(workspace, conv_id)
    session_uri_str = URI.to_string(session_uri)
    topic = "esr:session:#{session_uri_str}:events"

    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

    customer_msg = Ezagent.Message.new(customer_uri, %{text: text, attachments: []})

    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    # SSE preamble — open event documents the request shape for the
    # client and is also handy when grepping curl output.
    {:ok, conn} =
      sse_chunk(conn, "open", %{
        workspace: workspace,
        conv_id: conv_id,
        session_uri: session_uri_str,
        customer_uri: URI.to_string(customer_uri),
        sent_msg_id: customer_msg.id
      })

    dispatch_chat_send(session_uri, customer_msg, customer_uri)

    # Synthetic agent reply — see moduledoc. Fire-and-forget Task so the
    # controller goes straight to the receive loop.
    spawn_synthetic_reply(session_uri, text)

    conn =
      stream_loop(conn,
        agent_uri_str: @agent_uri_str,
        customer_uri_str: URI.to_string(customer_uri),
        deadline: System.monotonic_time(:millisecond) + @reply_timeout_ms
      )

    Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic)
    conn
  end

  def chat(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing required fields", required: ["customer_id", "text"]})
  end

  # ──────────────────────────────────────────────────────────────────
  # session URI shape

  # We reuse the session URI shape Phase 0 settled on:
  #   session://default/<workspace>/<conv_id>
  # i.e. `default` template, workspace authority segment, conv_id as
  # the session name. `setup.exs` pre-creates one with conv_id="c1"
  # but any future request with a fresh conv_id would need its own
  # session pre-created (out of scope for the PoC).
  defp session_uri_for(workspace, conv_id) do
    URI.parse("session://default/#{workspace}/#{conv_id}")
  end

  # ──────────────────────────────────────────────────────────────────
  # dispatch

  defp dispatch_chat_send(session_uri, msg, _customer_uri) do
    target = URI.new!(URI.to_string(session_uri) <> "?action=chat.send")
    # The customer is anonymous; we dispatch as the admin principal with
    # bootstrap caps. EXP-C3 doesn't try to solve "what caps does a
    # third-party-IM-relayed user hold" — that's a separate design
    # question.
    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{caller: admin_uri, caps: admin_caps, reply: :ignore}
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok -> :ok
      other -> Logger.warning("EXP-C3 dispatch chat.send failed: #{inspect(other)}")
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # synthetic reply (Phase 0 cc bridge work-around)

  defp spawn_synthetic_reply(session_uri, customer_text) do
    topic = "esr:session:#{URI.to_string(session_uri)}:events"
    agent_uri = URI.parse(@agent_uri_str)

    Task.start(fn ->
      Process.sleep(500)

      reply =
        Ezagent.Message.new(agent_uri, %{
          text: "Echo: " <> customer_text,
          attachments: []
        })

      # NB: this synthetic broadcast bypasses MessageStore.write —
      # documented in FINDINGS.
      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        topic,
        {:chat_message, session_uri, reply}
      )
    end)
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
