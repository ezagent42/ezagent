defmodule EzagentPluginLoom.OrchestratorServer do
  @moduledoc """
  Loom 编排进程（务实版 multi-agent wiring）。

  per-session GenServer,订阅 `esr:session:<uri>:events`,收到 customer 消息时:
  `compose_scene/1`(真实 LLM) → dispatch `turn.open` → `turn.compose(result_refs)` →
  `turn.settle`,从而 customer feed 在 operator 批准后读到真实编排产出。

  **不碰 domain**:全在 plugin 内,经标准 `Invocation.dispatch` 调 session 的 Turn action
  (P14 dispatch 唯一路径)。loop-guard:编排进程用独立 system 身份(`@caller`)dispatch,
  turn 产出消息的 sender = 该身份 → 被 `customer_message?/2` 跳过,不会自我触发死循环;
  worker 委派/deliver(带 turn correlation metadata)同样跳过。

  脚手架阶段是**单 agent 直出**(compose 直接产 chat+page,无 decompose/fan-out);后续加
  decompose → fan-out themed worker → 收集 的完整多 agent 形态。
  """
  use GenServer
  require Logger

  alias Ezagent.{Invocation, SystemPrincipal}
  alias Ezagent.Behavior.Session, as: SessionBehavior
  alias EzagentPluginLoom.Orchestrator

  @caller_uri "system://loom-orchestrator"

  def start_link(session_uri) when is_struct(session_uri, URI) do
    GenServer.start_link(__MODULE__, session_uri, name: via(session_uri))
  end

  defp via(session_uri) do
    {:via, Registry, {EzagentPluginLoom.OrchestratorRegistry, URI.to_string(session_uri)}}
  end

  @impl true
  def init(session_uri) do
    :ok =
      Phoenix.PubSub.subscribe(
        EzagentCore.PubSub,
        SessionBehavior.session_events_topic(session_uri)
      )

    {:ok, %{session_uri: session_uri, caller: Ezagent.URI.new!(@caller_uri)}}
  end

  @impl true
  def handle_info({:chat_message, _session_uri, msg}, state) do
    if customer_message?(msg, state.caller) do
      session_uri = state.session_uri
      caller = state.caller
      Task.start(fn -> orchestrate(session_uri, msg, caller) end)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # 只对真正的 customer/user 入站消息编排:排除编排进程自己产出的(sender == @caller)、
  # 以及带 turn correlation 的 worker 委派/deliver 消息。
  defp customer_message?(msg, caller) do
    URI.to_string(msg.sender) != URI.to_string(caller) and not turn_correlated?(msg) and
      is_binary(text_of(msg)) and text_of(msg) != ""
  end

  defp turn_correlated?(msg) do
    body = msg.body || %{}
    get_in(body, ["metadata", "correlation"]) != nil or get_in(body, [:metadata, :correlation]) != nil
  end

  defp text_of(msg) do
    body = msg.body || %{}
    body["text"] || body[:text]
  end

  defp orchestrate(session_uri, msg, caller) do
    with {:ok, result_refs} <- Orchestrator.run(text_of(msg)),
         {:ok, %{turn_id: turn_id}} <-
           dispatch(session_uri, "turn.open", caller, %{
             trigger: %{message_id: msg.id},
             opened_at: System.system_time(:millisecond)
           }),
         {:ok, _} <-
           dispatch(session_uri, "turn.compose", caller, %{
             turn_id: turn_id,
             result_refs: result_refs
           }),
         {:ok, _} <- dispatch(session_uri, "turn.settle", caller, %{turn_id: turn_id}) do
      :ok
    else
      # 无 LLM key 环境(普通 gate、未配 key 的 session)静默跳过,不污染日志/不开 turn。
      {:error, :no_api_key} -> :ok
      error -> Logger.warning("loom orchestrate failed: #{inspect(error)}")
    end
  end

  defp dispatch(session_uri, action, caller, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{action}"),
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        caps: SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end
end
