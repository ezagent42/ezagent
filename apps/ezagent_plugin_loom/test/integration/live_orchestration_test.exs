defmodule EzagentPluginLoom.Integration.LiveOrchestrationTest do
  @moduledoc """
  LIVE: 真实 LLM → loom orchestrator → Turn → customer feed 端到端。

  需真实端点(`DEEPSEEK_API_KEY`(provider key)),默认排除(`:live` tag)。
  跑: `DEEPSEEK_API_KEY=sk-... mix test --include live \
        apps/ezagent_plugin_loom/test/integration/live_orchestration_test.exs`

  证明 multi-agent wiring 第一片(单 agent compose)用真实 LLM 跑通:编排器把 customer
  意图变成 scene-card chat + page tree,经 Turn settle 后 customer feed 读到真实产出。
  """
  use EzagentCore.DataCase, async: false
  @moduletag :live
  @moduletag timeout: 180_000

  alias Ezagent.{Invocation, KindRegistry, Workspace, WorkspaceRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginLoom.{Orchestrator, Template.LoomSession}

  @valid_node_types ~w(text services companies detail steps form choices notice application intent page)

  setup do
    workspace_name = "loom-live-#{System.unique_integer([:positive])}"
    session_name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :loom, session_name)

    {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

    assert {:ok, [^session_uri], %{vertical: :loom}} =
             LoomSession.instantiate(
               "loom-main",
               %{
                 "class" => "session.loom",
                 "session_name" => session_name,
                 "operator_uri" => URI.to_string(User.admin_uri())
               },
               workspace_uri
             )

    assert {:ok, _pid} = KindRegistry.lookup(session_uri)
    assert {:ok, ^workspace_uri} = WorkspaceRegistry.lookup(session_uri)

    %{session: session_uri, token: CustomerAuth.issue_token(session_uri, workspace_uri)}
  end

  test "real LLM composes a scene the customer feed serves after settle", ctx do
    # 1) 真实 LLM 编排 customer 意图 → result_refs
    assert {:ok, result_refs} =
             Orchestrator.compose_scene("帮我做一个卖手冲咖啡的落地页，要有产品和下单入口")

    assert [%{kind: :chat, text: chat_text}, %{kind: :page, tree: page_tree}] = result_refs
    assert is_binary(chat_text) and chat_text != ""
    assert %{"type" => root_type, "children" => _} = page_tree
    assert root_type in @valid_node_types

    # 2) 喂进 Turn(open → compose → settle)
    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "live1"}, opened_at: 1})

    assert {:ok, %{status: :composing, version: version}} =
             dispatch(ctx.session, :turn, :compose, %{turn_id: turn_id, result_refs: result_refs})

    # 批准前 customer 看不到
    assert {:ok, %{messages: [], page: nil}} = CustomerFeed.snapshot(ctx.session, ctx.token)

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    # 3) settle 后 customer feed 读到真实 LLM 产出
    snapshot = wait_for_page(ctx.session, ctx.token, page_tree)
    assert snapshot.page == page_tree
    assert Enum.any?(snapshot.messages, &(message_text(&1) == chat_text))

    assert {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
    assert surface.approved == version
  end

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}"),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp message_text(message),
    do: Map.get(message.body, "text") || Map.get(message.body, :text)

  defp wait_for_page(session_uri, token, page_tree, attempts \\ 100)
  defp wait_for_page(_s, _t, _p, 0), do: flunk("customer feed never served the page")

  defp wait_for_page(session_uri, token, page_tree, attempts) do
    case CustomerFeed.snapshot(session_uri, token) do
      {:ok, %{page: ^page_tree} = snapshot} ->
        snapshot

      _ ->
        Process.sleep(20)
        wait_for_page(session_uri, token, page_tree, attempts - 1)
    end
  end
end
