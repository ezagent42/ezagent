defmodule EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug do
  @moduledoc """
  `POST /v1/chat/completions` — OpenAI-compatible inbound endpoint (#96 Phase 1).

  Per-endpoint plug for the OpenAI Chat Completions wire protocol. Shared
  concerns are delegated to the LLM Protocol API support layer:

    * `Ezagent.ProtocolApi.RequestNormalizer` — bearer/conversation/body parsing
    * `Ezagent.ProtocolApi.ReplyTransport` — request-scoped reply correlation
    * `Ezagent.ProtocolApi.ResponseRenderer` — protocol response shaping

  Ack-then-async-reply (handoff §2.3): POST returns `{id, status:"processing"}`
  immediately; a background Task waits for the agent reply; the client polls
  `GET /v1/chat/completions/:id` to retrieve the result.

  (Renamed from `EzagentPluginProtocolApi.OpenaiChatPlug` in #96.)
  """
  import Plug.Conn
  alias Ezagent.{Invocation, LocalRuntime, Message, Router, URI}

  alias Ezagent.ProtocolApi.{
    ApiKeyStore,
    ConversationRegistry,
    PendingReplyStore,
    RequestNormalizer,
    ResponseRenderer,
    ReplyTransport
  }

  @behaviour Plug
  # P2 — the default agent is the seeded `py_default` (echo.py py-agent) that
  # replaced the deleted echo default agent. Its stored flavor is `py`.
  @default_agent_name "py_default"
  @default_agent_flavor "py"

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
    with {:ok, body} <- RequestNormalizer.parse_body(conn),
         {:ok, token} <- RequestNormalizer.extract_bearer(conn),
         {:ok, entity_uri, workspace_uri, target_agent, _caps} <- ApiKeyStore.verify(token),
         {:ok, conversation_id} <- RequestNormalizer.extract_conversation_id(body, conn),
         {:ok, session_uri} <-
           ConversationRegistry.resolve(conversation_id, workspace_uri, entity_uri),
         :ok <- ensure_session_live(session_uri),
         :ok <- join_agent(session_uri, entity_uri, target_agent),
         {:ok, request_id, msg} <- build_message(body, entity_uri, target_agent),
         :ok <- dispatch_send(session_uri, entity_uri, msg) do
      agent = target_agent || default_agent_uri()

      # Register pending request, spawn background waiter (subscribes + waits in Task)
      PendingReplyStore.put_pending(request_id)

      ReplyTransport.spawn_waiter(
        request_id,
        agent,
        session_uri,
        entity_uri,
        &ResponseRenderer.openai_chat_completion(request_id, &1)
      )

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

  # Poll owner-gated liveness until agent appears (post-init activation completes).
  defp wait_for_kind_registry(agent_uri) do
    deadline = :erlang.monotonic_time(:millisecond) + 10_000
    wait_for_kind_registry(agent_uri, deadline)
  end

  defp wait_for_kind_registry(agent_uri, deadline) do
    cond do
      :erlang.monotonic_time(:millisecond) >= deadline ->
        :ok

      LocalRuntime.kind_alive?(agent_uri) ->
        :ok

      true ->
        Process.sleep(200)
        wait_for_kind_registry(agent_uri, deadline)
    end
  end

  # Register flavor attribute so AgentModuleResolver can find the Kind module.
  defp maybe_register_flavor(agent_uri) do
    case Ezagent.UriQuery.resolve(:flavor, agent_uri) do
      {:ok, flavor} -> Ezagent.AgentFlavorAttributes.put(agent_uri, flavor)
      _ -> maybe_register_default_agent(agent_uri)
    end
  end

  defp maybe_register_default_agent(agent_uri) do
    if URI.stable_key(agent_uri) == URI.stable_key(default_agent_uri()) do
      Ezagent.AgentFlavorAttributes.put(agent_uri, @default_agent_flavor)
    else
      :ok
    end
  end

  defp extract_id_from_path(conn) do
    path = conn.request_path

    case String.split(path, "/v1/chat/completions/") do
      [_, id] when byte_size(id) > 0 -> {:ok, id}
      _ -> :error
    end
  end

  # Spawn the target agent (if any) and join it to the session.
  # Defaults to echo agent when target_agent is nil.
  defp join_agent(session_uri, entity_uri, target_agent) do
    require Logger
    agent = target_agent || default_agent_uri()
    Logger.info("ProtocolApi: spawning agent #{inspect(agent)}...")

    # Register flavor attribute so AgentModuleResolver can find the Kind module.
    # Flavor comes from the STORED attribute (`Ezagent.UriQuery.resolve(:flavor, …)`),
    # NOT parsed from the URI name prefix (the `cc_`/`codex_`/`curl_` prefix-magic was
    # removed — flavor is a stored attribute, not derived from the name; #931 + lead
    # 2026-06-24). A non-echo target with no stored flavor must be provisioned first;
    # only the default echo agent is auto-registered (see `maybe_register_default_echo/1`).
    maybe_register_flavor(agent)

    case LocalRuntime.ensure_started(agent) do
      {:ok, _pid} ->
        Logger.info("ProtocolApi: agent spawned OK")

      {:error, :already_started} ->
        Logger.info("ProtocolApi: agent already started")

      {:error, reason} ->
        Logger.error("ProtocolApi: agent spawn failed: #{inspect(reason)}")
        {:error, 500, "spawn_failed", inspect(reason)}
    end

    # Wait for agent post-init activation. Freshly spawned agents need time
    # for handle_continue callbacks to register in KindRegistry AND snapshot
    # writes to flush to DB (needed by AgentBridge load_sandbox_respawn).
    wait_for_kind_registry(agent)
    Process.sleep(3000)

    target = URI.with_action(session_uri, :session, :join)

    cmd = %Ezagent.Cmd{
      target: target,
      action: :join,
      args: %{member: agent},
      ctx: %{caller: entity_uri, authenticated_principal: entity_uri, caps: MapSet.new(), reply: :ignore},
      origin: :authenticated_external
    }

    Logger.info("ProtocolApi: joining agent to session...")

    case Router.dispatch(cmd) do
      {:ok, _} ->
        Logger.info("ProtocolApi: join OK")
        :ok

      :ok ->
        Logger.info("ProtocolApi: join OK")
        :ok

      {:error, reason} ->
        Logger.error("ProtocolApi: join failed: #{inspect(reason)}")
        {:error, 500, "join_failed", inspect(reason)}
    end
  end

  defp ensure_session_live(session_uri) do
    case LocalRuntime.ensure_live(session_uri) do
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
    agent = target_agent || default_agent_uri()
    mentions = if agent, do: [agent], else: []

    msg =
      Message.new(entity_uri, %{text: text, attachments: []},
        id: request_id,
        mentions: mentions
      )

    {:ok, request_id, msg}
  end

  @doc "URI of the default agent used when an API key carries no `target_agent`."
  @spec default_agent_uri() :: URI.t()
  def default_agent_uri, do: URI.agent("system", @default_agent_name)

  @doc "Stored flavor of the default agent (`py`) — registered by `maybe_register_default_agent/1`."
  @spec default_agent_flavor() :: String.t()
  def default_agent_flavor, do: @default_agent_flavor

  defp dispatch_send(session_uri, entity_uri, msg) do
    target = URI.with_action(session_uri, :session, :send)

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{message: msg},
      ctx: %{caller: entity_uri, authenticated_principal: entity_uri, caps: MapSet.new(), reply: :sync},
      origin: :authenticated_external
    }

    case Invocation.dispatch(inv) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, 422, "dispatch", inspect(reason)}
    end
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
