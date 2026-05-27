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

  Lifecycle per request:
    1. Validate `:workspace` exists; mint customer entity URI
       `entity://user/<workspace>/customer_<customer_id>`.
    2. Compute / generate `conv_id`, derive session URI, ensure
       session exists (idempotent create).
    3. Subscribe to the session events topic
       `esr:session:<session_uri>:events`.
    4. Open the SSE stream and dispatch `chat.send` with the customer
       message as the bootstrap-cap'd caller.
    5. **PHASE_2.4_TODO** — fire a synthetic-reply Task (500ms) that
       broadcasts a `{:chat_message, session_uri, %Ezagent.Message{}}`
       tuple back into the session topic. Phase 2.4 will replace this
       with real cc bridge dispatch (EagerBridge ensures the bridge
       is bound before customer traffic arrives) and the SSE loop will
       just relay whatever cc emits. See `spawn_synthetic_reply/2`.
    6. Loop forever (until timeout / terminal reply / connection
       close): receive `{:chat_message, _, msg}` and `chunk` it back
       to the client as an SSE event. Skip the customer's own echo
       (sender == customer_uri) so the client only sees agent traffic.

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

  # PHASE_2.4_TODO — Agent URI used by the synthetic-reply path. In
  # Phase 2.4 this becomes the real cc agent URI resolved from session
  # membership (cs_main per workspace). Until then, the fixture lets
  # the SSE loop recognize "terminal" without depending on session
  # member state.
  @agent_uri_str "entity://user/__synthetic__/echo_agent"

  def chat(conn, %{"customer_id" => cust_id, "text" => text} = params)
      when is_binary(cust_id) and is_binary(text) do
    workspace = Map.get(conn.path_params, "workspace") || Map.get(params, "workspace")

    case validate_workspace(workspace) do
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
        nil -> generate_conv_id()
        "" -> generate_conv_id()
        id when is_binary(id) -> id
      end

    customer_uri = URI.parse("entity://user/#{workspace}/customer_#{cust_id}")
    session_uri = session_uri_for(workspace, conv_id)
    session_uri_str = URI.to_string(session_uri)
    topic = "esr:session:#{session_uri_str}:events"

    :ok = ensure_session(workspace, conv_id)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

    customer_msg = Ezagent.Message.new(customer_uri, %{text: text, attachments: []})

    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} =
      sse_chunk(conn, "open", %{
        workspace: workspace,
        conv_id: conv_id,
        session_uri: session_uri_str,
        customer_uri: URI.to_string(customer_uri),
        sent_msg_id: customer_msg.id
      })

    dispatch_chat_send(session_uri, customer_msg)

    # PHASE_2.4_TODO — replace this synthetic-reply spawn with real cc
    # bridge dispatch (EagerBridge.ensure_bound!/2 + chat.receive to
    # the cc agent URI). Until then, the synthetic echo proves the SSE
    # plumbing end-to-end without requiring the bridge handshake to
    # have completed. See poc/phase-2/3-C3-channel-rebase.md.
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

  # ──────────────────────────────────────────────────────────────────
  # workspace validation
  #
  # The `:workspace` URL segment is the tenant. We refuse to dispatch
  # against a workspace that doesn't exist in `Ezagent.Workspace.Store`
  # — otherwise `EzagentDomainChat.create_session/3` would create a
  # session against a non-existent workspace and the dispatch would
  # fail downstream with a much less helpful error.

  defp validate_workspace(nil), do: {:error, "workspace path segment required"}
  defp validate_workspace(""), do: {:error, "workspace path segment required"}

  defp validate_workspace(name) when is_binary(name) do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil -> {:error, "workspace not found"}
      _ws -> :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # session URI shape — per Phase 1+2 verdict §2
  #   session://default/<workspace>/<conv_id>
  # `default` is the template name; the 3-segment authority is
  # `<workspace>/<conv_id>`. Concurrent conversations get isolated
  # session URIs and therefore isolated PubSub topics — verified by
  # the EXP-C{1,2,3} concurrency tests.

  defp session_uri_for(workspace, conv_id) do
    URI.parse("session://default/#{workspace}/#{conv_id}")
  end

  defp generate_conv_id do
    # Short URL-safe id; 64 bits of entropy is plenty for an interactive
    # chat session that lives for the duration of one HTTP request.
    Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  # Idempotent — `create_session/3` returns
  # `{:error, {:already_started, _}}` on adoption paths, which we treat
  # as success. Returns :ok on either fresh create or already-alive.
  defp ensure_session(workspace, conv_id) do
    admin_uri = Ezagent.Entity.User.admin_uri()

    case EzagentDomainChat.create_session(conv_id, admin_uri,
           workspace_uri: URI.parse("workspace://#{workspace}"),
           template_name: "default"
         ) do
      {:ok, _session_uri, _meta} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Phase 2.3 ensure_session(#{workspace}, #{conv_id}) failed: " <>
            inspect(reason) <> " — proceeding; chat.send may also fail."
        )

        :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # dispatch

  defp dispatch_chat_send(session_uri, msg) do
    target = URI.new!(URI.to_string(session_uri) <> "?action=chat.send")
    # The customer is anonymous; we dispatch as the admin principal with
    # bootstrap caps. Phase 2.x does not try to solve "what caps does a
    # third-party-IM-relayed user hold" — that's a separate design
    # question (open in phase-1-2-verdict.md §6).
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
      other -> Logger.warning("Phase 2.3 dispatch chat.send failed: #{inspect(other)}")
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # PHASE_2.4_TODO — synthetic reply (to be replaced with cc bridge).
  #
  # Current behavior: 500ms after the customer sends, broadcast a fake
  # "Echo: ..." reply directly onto the session PubSub topic. This
  # bypasses MessageStore.write (acceptable for the PoC; documented in
  # poc/exp-C3/FINDINGS.md).
  #
  # Phase 2.4 replacement (planned):
  #   1. `EzagentPluginCc.EagerBridge.ensure_bound!(cc_agent_uri, _opts)`
  #      to guarantee the bridge is alive before dispatching.
  #   2. `Invocation.dispatch(chat.receive)` against `cc_agent_uri` with
  #      the customer message in args.
  #   3. cc replies normally via the bridge; its reply message lands on
  #      the same `esr:session:.../events` topic this controller is
  #      already subscribed to, so the SSE loop relays it unchanged.
  #
  # The SWAP-OUT POINT is this entire function. The stream_loop's
  # "terminal == sender_str == agent_uri_str" check stays — it just
  # starts seeing real cc URIs instead of `@agent_uri_str`.

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
