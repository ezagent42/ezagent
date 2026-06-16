defmodule EzagentPluginLoom.Integration.LiveWiringTest do
  @moduledoc """
  LIVE: 务实版 multi-agent wiring 端到端 —— customer 消息 → 编排进程(订阅) →
  真实 LLM compose → Turn → customer feed。

  需 `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`,默认排除(`:live`)。跑:
  `ANTHROPIC_BASE_URL=... ANTHROPIC_API_KEY=... mix test --include live \
     apps/ezagent_plugin_loom/test/integration/live_wiring_test.exs`

  证明:一条进 session 的 customer 消息,经 `OrchestratorServer` 订阅感知 → 真实 LLM
  编排成 scene-card chat + page → dispatch Turn open/compose/settle → customer feed
  在 settle 后读到真实产出。无人工 dispatch turn —— 全自动 wiring。
  """
  use EzagentCore.DataCase, async: false
  @moduletag :live
  @moduletag timeout: 180_000

  alias Ezagent.{Invocation, Message, Workspace, WorkspaceRegistry, KindRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginLoom.{OrchestratorServer, Template.LoomSession}

  @valid_node_types ~w(text services companies detail steps form choices notice application intent page)

  test "a customer message auto-drives orchestration to the customer feed", _ctx do
    workspace_name = "loom-wire-#{System.unique_integer([:positive])}"
    session_name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :loom, session_name)

    {:ok, _ws} = Workspace.create(workspace_name, %{})

    assert {:ok, [^session_uri], _} =
             LoomSession.instantiate(
               "loom-main",
               %{
                 "class" => "session.loom",
                 "session_name" => session_name,
                 "operator_uri" => URI.to_string(User.admin_uri())
               },
               workspace_uri
             )

    assert {:ok, _} = KindRegistry.lookup(session_uri)
    assert {:ok, ^workspace_uri} = WorkspaceRegistry.lookup(session_uri)

    # 起编排进程(生产路径:DynamicSupervisor 起 per-session OrchestratorServer)
    assert {:ok, _orch_pid} =
             DynamicSupervisor.start_child(
               EzagentPluginLoom.OrchestratorSupervisor,
               {OrchestratorServer, session_uri}
             )

    token = CustomerAuth.issue_token(session_uri, workspace_uri)

    # 模拟一条 customer 入站消息(operator/admin 身份发,与编排进程身份不同 → 触发编排)
    msg = Message.new(User.admin_uri(), %{text: "帮我做一个卖手冲咖啡的落地页，要有产品和下单"})

    assert :ok =
             Invocation.dispatch(%Invocation{
               target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
               mode: :cast,
               args: %{message: msg},
               ctx: %{
                 caller: User.admin_uri(),
                 caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                 reply: :ignore
               }
             })

    # 编排进程异步:真实 LLM compose → turn open/compose/settle。等 customer feed 出现 page。
    snapshot = wait_for_page(session_uri, token)

    assert %{"type" => root_type, "children" => _} = snapshot.page
    assert root_type in @valid_node_types
    assert snapshot.messages != []

    # surface 也落了 approved 版本
    assert {:ok, surface} = Ezagent.Kind.get_slice(session_uri, :surface)
    refute is_nil(surface.approved)
  end

  defp wait_for_page(session_uri, token, attempts \\ 300)
  defp wait_for_page(_s, _t, 0), do: flunk("customer feed never served an orchestrated page")

  defp wait_for_page(session_uri, token, attempts) do
    case CustomerFeed.snapshot(session_uri, token) do
      {:ok, %{page: page} = snapshot} when not is_nil(page) ->
        snapshot

      _ ->
        Process.sleep(50)
        wait_for_page(session_uri, token, attempts - 1)
    end
  end
end
