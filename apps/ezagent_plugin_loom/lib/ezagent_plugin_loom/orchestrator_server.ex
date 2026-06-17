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
      not agent_sender?(msg.sender) and is_binary(text_of(msg)) and text_of(msg) != ""
  end

  # 排除 agent 发的消息(v0/worker 回复)——否则 v0 的 page_update 回帖会再触发编排 → 死循环。
  defp agent_sender?(%URI{} = uri), do: String.contains?(URI.to_string(uri), "/agent/")
  defp agent_sender?(_), do: false

  defp turn_correlated?(msg) do
    body = msg.body || %{}

    get_in(body, ["metadata", "correlation"]) != nil or
      get_in(body, [:metadata, :correlation]) != nil
  end

  defp text_of(msg) do
    body = msg.body || %{}
    body["text"] || body[:text]
  end

  @doc """
  Seed 一张初始页(无 LLM)—— 作 **page_update span**(starter JSX)发进 session,让真实
  loom 前端(loom_ui)打开即有 starter 页 + 立即可发布(publish 读 page_update span)。
  `files` 给定则 seed 它(saved_template / fork 复用),否则 starter。best-effort。
  """
  @spec seed_page(URI.t(), map() | nil) :: :ok
  def seed_page(session_uri, files \\ nil)

  def seed_page(%URI{} = session_uri, files) do
    page_files = if is_map(files) and map_size(files) > 0, do: files, else: starter_files()

    page = %{
      "files" => page_files,
      "source" => Map.get(page_files, "/App.jsx", ""),
      "summary" => "初始页"
    }

    EzagentPluginLoom.PageStore.put(session_uri, page_files)
    emit_v0(session_uri, ~s(<span type="page_update">#{Jason.encode!(page)}</span>))
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # starter 页 = 一个合法 React App(Sandpack 直接渲染),提示用户在聊天框描述需求。
  defp starter_files do
    %{
      "/App.jsx" => """
      export default function App() {
        return (
          <div className="min-h-screen flex items-center justify-center bg-gray-50">
            <div className="text-center p-8">
              <h1 className="text-3xl font-bold text-gray-900">欢迎使用 Loom</h1>
              <p className="mt-3 text-gray-500">在左侧聊天框描述你想要的页面,我来帮你生成并实时预览。</p>
            </div>
          </div>
        );
      }
      """
    }
  end

  # Phase 2:用回 loom 原本的 v0 页面生成 —— 调 V0(走对齐 LLM)产 `page_update` JSX span,
  # 作 v0 agent 的消息发进 session;前端 loom_ui 从 history/stream 读该 span → Sandpack 预览。
  # (socialware Turn/surface 的 UI-tree 模型用于 customer 审批流,builder 预览走 loom 自己的引擎。)
  defp orchestrate(session_uri, msg, _caller) do
    text = text_of(msg)

    case EzagentPluginLoom.V0.generate(text,
           current_files: read_current_files(session_uri),
           session_uri: session_uri
         ) do
      {:page_update, span, files} ->
        EzagentPluginLoom.PageStore.put(session_uri, files)
        emit_v0(session_uri, span)

      {:prose, prose} ->
        emit_v0(session_uri, prose)

      {:error, reason} when reason in [:no_api_key, {:no_api_key, "DEEPSEEK_API_KEY"}] ->
        :ok

      {:error, {:no_api_key, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning("loom v0 failed: #{inspect(reason)}")
    end
  end

  # 以 loomv0 agent(session Member)身份把 v0 产出发进 session(chat.send / session.send)。
  defp emit_v0(session_uri, body_text) do
    case ws_sid(session_uri) do
      {ws, sid} ->
        sender = Ezagent.URI.agent(ws, "loomv0_#{sid}")
        msg = Ezagent.Message.new(sender, %{text: body_text})
        dispatch(session_uri, "session.send", sender, %{message: msg})
        :ok

      _ ->
        :ok
    end
  end

  # 读当前页 files(最近一条含 page_update span 的消息)→ 供 v0 增量改。无 → nil。
  # 最近一条 page_update 的 files(newest-first,不 reverse → 取最新)。
  defp read_current_files(session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(50)
    |> Enum.find_value(nil, fn m ->
      with text when is_binary(text) <- text_of(m),
           [_, json] <- Regex.run(~r/<span type="page_update">([\s\S]*?)<\/span>/, text),
           {:ok, %{"files" => files}} when is_map(files) <- Jason.decode(json) do
        files
      else
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  end

  defp ws_sid(%URI{scheme: "session", host: ws, path: "/loom/" <> sid})
       when is_binary(ws) and is_binary(sid) and sid != "",
       do: {ws, sid}

  defp ws_sid(_), do: nil

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
