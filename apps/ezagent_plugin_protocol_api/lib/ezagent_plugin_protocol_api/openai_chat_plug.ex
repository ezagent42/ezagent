defmodule EzagentPluginProtocolApi.OpenaiChatPlug do
  @moduledoc """
  `POST /v1/chat/completions` — OpenAI-compatible inbound endpoint.
  Flow: parse → auth → resolve session → build Message →
  subscribe Publisher → dispatch session.send → wait reply → return JSON.
  """
  import Plug.Conn
  alias Ezagent.{Invocation, Message, Router, SpawnRegistry, URI}
  alias Ezagent.ProtocolApi.{ApiKeyStore, ConversationRegistry, ReplyWaiter}
  @behaviour Plug
  @deadline_ms 120_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.method do
      "POST" -> handle_post(conn)
      _ -> json_error(conn, 405, "only POST is supported")
    end
  end

  defp handle_post(conn) do
    with {:ok, body} <- parse_body(conn),
         {:ok, token} <- extract_bearer(conn),
         {:ok, entity_uri, workspace_uri, _caps} <- ApiKeyStore.verify(token),
         {:ok, conversation_id} <- extract_conversation_id(body, conn),
         {:ok, session_uri} <- ConversationRegistry.resolve(conversation_id, workspace_uri, entity_uri),
         :ok <- ensure_session_live(session_uri),
         {:ok, request_id, msg} <- build_message(body, entity_uri),
         {:ok, _cursor} <- subscribe_publisher(session_uri),
         :ok <- dispatch_send(session_uri, entity_uri, msg) do
      case ReplyWaiter.wait_for_reply(request_id, entity_uri, @deadline_ms) do
        {:ok, reply_msg} -> json_response(conn, 200, build_openai_response(request_id, reply_msg))
        {:error, :timeout} -> json_error(conn, 504, "timed out waiting for agent reply")
      end
    else
      {:error, status, code, detail} -> json_error(conn, status, "#{code}: #{detail}")
      {:error, reason} -> json_error(conn, 400, inspect(reason))
    end
  end

  defp parse_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, 400, "bad_json", "invalid JSON body"}
        end
      {:error, reason} -> {:error, 400, "bad_body", inspect(reason)}
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, 401, "missing_token", "Authorization: Bearer <token> required"}
    end
  end

  defp extract_conversation_id(body, conn) do
    case Map.get(body, "conversation_id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ ->
        case Plug.Conn.get_req_header(conn, "x-conversation-id") do
          [id | _] when id != "" -> {:ok, id}
          _ -> {:error, 400, "missing_conversation_id", "conversation_id field or X-Conversation-Id header required"}
        end
    end
  end

  defp ensure_session_live(session_uri) do
    case SpawnRegistry.ensure_live(session_uri) do
      {:ok, :live} -> :ok
      {:ok, :rehydrated} -> :ok
      {:error, reason} -> {:error, 500, "session_live", inspect(reason)}
    end
  end

  defp build_message(body, entity_uri) do
    request_id = Message.generate_id()
    messages = Map.get(body, "messages", [])
    text = messages |> List.last() |> case do
      %{"content" => content} when is_binary(content) -> content
      _ -> ""
    end
    msg = Message.new(entity_uri, %{text: text, attachments: []}, id: request_id)
    {:ok, request_id, msg}
  end

  defp subscribe_publisher(session_uri) do
    target = URI.with_action(session_uri, :publisher, :subscribe_from)
    cmd = %Ezagent.Cmd{
      target: target, action: :subscribe_from,
      args: %{subscriber_pid: self(), cursor: :latest},
      ctx: %{caller: Ezagent.URI.system_principal("plugins")}
    }
    case Router.dispatch(cmd) do
      {:ok, %{cursor: cursor}} -> {:ok, cursor}
      {:error, reason} -> {:error, 500, "subscribe", inspect(reason)}
    end
  end

  defp dispatch_send(session_uri, entity_uri, msg) do
    target = URI.with_action(session_uri, :session, :send)
    inv = %Invocation{
      target: target, mode: :call, args: %{message: msg},
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
      "object" => "chat.completion", "created" => DateTime.utc_now() |> DateTime.to_unix(),
      "model" => "ezagent",
      "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => Map.get(reply_msg.body, :text, "") || ""}, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
    }
  end

  defp json_response(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  defp json_error(conn, status, message) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(%{"error" => %{"message" => message, "type" => "api_error"}}))
  end
end
