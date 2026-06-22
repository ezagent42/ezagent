defmodule EzagentPluginProtocolApi.OpenaiChatPlug do
  @moduledoc """
  `POST /v1/chat/completions` — OpenAI-compatible inbound endpoint.

  Ack-then-async-reply (handoff §2.3): POST returns `{id, status:"processing"}`
  immediately; a background Task waits for the agent reply; the client polls
  `GET /v1/chat/completions/:id` to retrieve the result.
  """
  import Plug.Conn
  alias Ezagent.{Invocation, Message, Router, SpawnRegistry, URI}
  alias Ezagent.ProtocolApi.{ApiKeyStore, ConversationRegistry, PendingReplyStore, ReplyWaiter}
  @behaviour Plug
  @deadline_ms 120_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case {conn.method, extract_id_from_path(conn)} do
      {"POST", _} -> handle_post(conn)
      {"GET", {:ok, id}} -> handle_retrieve(conn, id)
      {"GET", _} -> json_error(conn, 400, "missing request id in path")
      _ -> json_error(conn, 405, "only POST/GET is supported")
    end
  end

  # Ack-then-async-reply (handoff §2.3): validate + set up synchronously,
  # spawn background Task for the waiter, return ack immediately.
  defp handle_post(conn) do
    with {:ok, body} <- parse_body(conn),
         {:ok, token} <- extract_bearer(conn),
         {:ok, entity_uri, workspace_uri, target_agent, _caps} <- ApiKeyStore.verify(token),
         {:ok, conversation_id} <- extract_conversation_id(body, conn),
         {:ok, session_uri} <-
           ConversationRegistry.resolve(conversation_id, workspace_uri, entity_uri),
         :ok <- ensure_session_live(session_uri),
         :ok <- join_agent(session_uri, entity_uri, target_agent),
         {:ok, request_id, msg} <- build_message(body, entity_uri, target_agent),
         :ok <- dispatch_send(session_uri, entity_uri, msg) do
      agent = target_agent || Ezagent.URI.new!("entity://system/agent/echo_default")

      # Register pending request, spawn background waiter (subscribes + waits in Task)
      PendingReplyStore.put_pending(request_id)
      spawn_waiter(request_id, agent, session_uri, entity_uri)

      # Return ack immediately
      json_response(conn, 202, %{
        "id" => request_id,
        "object" => "chat.completion.pending",
        "status" => "processing",
        "retrieve_url" => "/v1/chat/completions/#{request_id}"
      })
    else
      {:error, status, code, detail} -> json_error(conn, status, "#{code}: #{detail}")
      {:error, reason} -> json_error(conn, 400, inspect(reason))
    end
  end

  # Background task: subscribe to Publisher, wait for reply, store result.
  defp spawn_waiter(request_id, agent, session_uri, entity_uri) do
    Task.start(fn ->
      # Subscribe to Publisher from THIS task's PID
      with {:ok, _cursor} <- subscribe_publisher(session_uri, entity_uri) do
        case ReplyWaiter.wait_for_reply(request_id, agent, @deadline_ms) do
          {:ok, reply_msg} ->
            PendingReplyStore.put_reply(request_id, build_openai_response(request_id, reply_msg))
          {:error, :timeout} ->
            PendingReplyStore.put_error(request_id, "timed out waiting for agent reply")
        end
      else
        {:error, reason} ->
          PendingReplyStore.put_error(request_id, "subscribe failed: #{inspect(reason)}")
      end
    end)
  end

  # GET /v1/chat/completions/:id — retrieve async result.
  defp handle_retrieve(conn, request_id) do
    case PendingReplyStore.get(request_id) do
      {:ok, :pending} ->
        json_response(conn, 200, %{"id" => request_id, "status" => "processing"})
      {:ok, reply} ->
        PendingReplyStore.delete(request_id)
        json_response(conn, 200, reply)
      {:error, error} ->
        PendingReplyStore.delete(request_id)
        json_response(conn, 200, %{"id" => request_id, "status" => "error", "error" => error})
      :not_found ->
        json_error(conn, 404, "request #{request_id} not found")
    end
  end

  defp extract_id_from_path(conn) do
    path = conn.request_path
    case String.split(path, "/v1/chat/completions/") do
      [_, id] when byte_size(id) > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_body(conn) do
    # Phoenix endpoint's Plug.Parsers already parses JSON body into conn.params
    # when Content-Type is application/json, so read_body returns "".
    # Use conn.params (which includes body_params after parsing).
    body_params = conn.body_params

    if body_params != %Plug.Conn.Unfetched{} and map_size(body_params) > 0 do
      {:ok, body_params}
    else
      {:error, 400, "bad_json", "invalid or empty JSON body"}
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, 401, "missing_token", "Authorization: Bearer <token> required"}
    end
  end

  defp extract_conversation_id(body, conn) do
    # Durable path: explicit conversation_id in body or header
    case Map.get(body, "conversation_id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ ->
        case Plug.Conn.get_req_header(conn, "x-conversation-id") do
          [id | _] when id != "" -> {:ok, id}
          # Stateless fallback (handoff §2.2): no conversation_id → ephemeral session
          _ -> {:ok, nil}
        end
    end
  end

  # Spawn the target agent (if any) and join it to the session.
  # Defaults to echo agent when target_agent is nil.
  defp join_agent(session_uri, entity_uri, target_agent) do
    require Logger
    agent = target_agent || Ezagent.URI.new!("entity://system/agent/echo_default")
    Logger.info("ProtocolApi: spawning agent #{inspect(agent)}...")

    case SpawnRegistry.spawn(agent) do
      {:ok, _pid} -> Logger.info("ProtocolApi: agent spawned OK")
      {:error, :already_started} -> Logger.info("ProtocolApi: agent already started")
      {:error, reason} ->
        Logger.error("ProtocolApi: agent spawn failed: #{inspect(reason)}")
        {:error, 500, "spawn_failed", inspect(reason)}
    end

    target = URI.with_action(session_uri, :session, :join)
    cmd = %Ezagent.Cmd{
      target: target, action: :join, args: %{member: agent},
      ctx: %{caller: entity_uri, caps: MapSet.new(), reply: :ignore}
    }
    Logger.info("ProtocolApi: joining agent to session...")
    case Router.dispatch(cmd) do
      {:ok, _} -> Logger.info("ProtocolApi: join OK"); :ok
      :ok -> Logger.info("ProtocolApi: join OK"); :ok
      {:error, reason} ->
        Logger.error("ProtocolApi: join failed: #{inspect(reason)}")
        {:error, 500, "join_failed", inspect(reason)}
    end
  end

  defp ensure_session_live(session_uri) do
    case SpawnRegistry.ensure_live(session_uri) do
      {:ok, :live} -> :ok
      {:ok, :rehydrated} -> :ok
      {:error, reason} -> {:error, 500, "session_live", inspect(reason)}
    end
  end

  defp build_message(body, entity_uri, target_agent) do
    request_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    messages = Map.get(body, "messages", [])

    text =
      messages
      |> List.last()
      |> case do
        %{"content" => content} when is_binary(content) -> content
        _ -> ""
      end

    # $session_users only delivers to Users. Add target agent to mentions
    # so the $mentions routing rule delivers agent.receive to it.
    agent = target_agent || Ezagent.URI.new!("entity://system/agent/echo_default")
    mentions = if agent, do: [agent], else: []

    msg =
      Message.new(entity_uri, %{text: text, attachments: []},
        id: request_id,
        mentions: mentions
      )

    {:ok, request_id, msg}
  end

  defp subscribe_publisher(session_uri, entity_uri) do
    # Subscribe from the CALLING process (Task PID for async, Plug PID for sync)
    target = URI.with_action(session_uri, :publisher, :subscribe_from)
    cmd = %Ezagent.Cmd{
      target: target,
      action: :subscribe_from,
      args: %{subscriber_pid: self(), cursor: :latest},
      ctx: %{caller: entity_uri, caps: MapSet.new()}
    }

    case Router.dispatch(cmd) do
      {:ok, %{cursor: cursor}} -> {:ok, cursor}
      {:error, reason} -> {:error, 500, "subscribe", inspect(reason)}
    end
  end

  defp dispatch_send(session_uri, entity_uri, msg) do
    target = URI.with_action(session_uri, :session, :send)

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{message: msg},
      ctx: %{caller: entity_uri, caps: MapSet.new(), reply: :sync}
    }

    case Invocation.dispatch(inv) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, 422, "dispatch", inspect(reason)}
    end
  end

  defp build_openai_response(request_id, %Message{} = reply_msg) do
    %{
      "id" => "chatcmpl-#{request_id}",
      "object" => "chat.completion",
      "created" => DateTime.utc_now() |> DateTime.to_unix(),
      "model" => "ezagent",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => Map.get(reply_msg.body, :text) || Map.get(reply_msg.body, "text") || ""
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
    }
  end

  defp json_response(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  defp json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{"error" => %{"message" => message, "type" => "api_error"}})
    )
  end
end
