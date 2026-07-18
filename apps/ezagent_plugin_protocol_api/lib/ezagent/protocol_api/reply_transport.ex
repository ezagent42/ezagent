defmodule Ezagent.ProtocolApi.ReplyTransport do
  @moduledoc """
  Request-scoped reply transport for the LLM Protocol API (#96 Phase 1).

  This is the shared "request → agent reply" correlation layer gaga's evaluation
  identifies as the core of the Protocol API (not REST): an inbound HTTP request
  dispatches into a session, then this transport subscribes to the session
  publisher, waits for the correlated agent reply, and stores a protocol-shaped
  result for the client to retrieve.

  Protocol-specific rendering is injected via `render_fun` so every endpoint
  (OpenAI chat-completions today; OpenAI responses / Anthropic messages in
  Phase 2) reuses the same wait/correlate/store flow.
  """

  require Logger
  alias Ezagent.{Message, Router, URI}
  alias Ezagent.ProtocolApi.{PendingReplyStore, ReplyWaiter}

  @deadline_ms 120_000

  @doc """
  Spawn a background task that subscribes to the session publisher, waits for the
  agent reply correlated to `request_id`, and stores the rendered result (or an
  error) in `PendingReplyStore`.

  `render_fun` maps the reply `Ezagent.Message` to the protocol response body,
  e.g. `&Ezagent.ProtocolApi.ResponseRenderer.openai_chat_completion(request_id, &1)`.
  """
  @spec spawn_waiter(String.t(), URI.t(), URI.t(), URI.t(), (Message.t() -> map())) ::
          {:ok, pid()} | {:error, term()}
  def spawn_waiter(request_id, agent, session_uri, entity_uri, render_fun)
      when is_function(render_fun, 1) do
    Task.start(fn ->
      # Subscribe to Publisher from THIS task's PID
      with {:ok, _cursor} <- subscribe_publisher(session_uri, entity_uri) do
        case ReplyWaiter.wait_for_reply(request_id, agent, @deadline_ms) do
          {:ok, reply_msg} ->
            PendingReplyStore.put_reply(request_id, render_fun.(reply_msg))

          {:error, :timeout} ->
            PendingReplyStore.put_error(request_id, "timed out waiting for agent reply")
        end
      else
        {:error, reason} ->
          PendingReplyStore.put_error(request_id, "subscribe failed: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Subscribe the calling process to the session publisher (cursor `:latest`).

  Must be called from the process that will receive the reply (the waiter task).
  """
  @spec subscribe_publisher(URI.t(), URI.t()) ::
          {:ok, term()} | {:error, pos_integer(), String.t(), String.t()}
  def subscribe_publisher(session_uri, entity_uri) do
    target = URI.with_action(session_uri, :publisher, :subscribe_from)

    cmd = %Ezagent.Cmd{
      target: target,
      action: :subscribe_from,
      args: %{subscriber_pid: self(), cursor: :latest},
      ctx: %{caller: entity_uri, caps: MapSet.new()},
      origin: :trusted_internal
    }

    case Router.dispatch(cmd) do
      {:ok, %{cursor: cursor}} -> {:ok, cursor}
      {:error, reason} -> {:error, 500, "subscribe", inspect(reason)}
    end
  end
end
