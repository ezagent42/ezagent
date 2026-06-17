defmodule EzagentPluginLoom.Integration.SwDevUpdTest do
  @moduledoc """
  loom vertical 的 SW-DEV / SW-UPD E2E(设计 §9 另两段;SW-USE 见 sw_use_logic_test)。

  - SW-DEV:operator 主动创作一页 → settle → customer 看到。
  - SW-UPD:已有 approved 页 → 第二轮 turn 产新版本 → settle → approved 指针前移、customer
    看到新版、旧版仍在 versions(不可变历史)。
  纯 Turn/Surface 机制(直接 dispatch,result_refs 固定),不需 LLM。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Workspace, WorkspaceRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginLoom.Template.LoomSession

  setup do
    ws = "loom-devupd-#{System.unique_integer([:positive])}"
    sid = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :loom, sid)
    {:ok, _} = Workspace.create(ws, %{})

    {:ok, [^session_uri], _} =
      LoomSession.instantiate(
        "loom-main",
        %{"class" => "session.loom", "session_name" => sid, "operator_uri" => URI.to_string(User.admin_uri())},
        workspace_uri
      )

    assert {:ok, _} = KindRegistry.lookup(session_uri)
    assert {:ok, ^workspace_uri} = WorkspaceRegistry.lookup(session_uri)
    %{session: session_uri, token: CustomerAuth.issue_token(session_uri, workspace_uri)}
  end

  test "SW-DEV: operator authors a page; customer sees it after settle", ctx do
    page = %{"type" => "services", "props" => %{"title" => "operator authored"}, "children" => []}

    {:ok, %{turn_id: t1}} = dispatch(ctx.session, "turn.open", %{trigger: %{message_id: "dev"}, opened_at: 1})

    {:ok, %{version: v1}} =
      dispatch(ctx.session, "turn.compose", %{
        turn_id: t1,
        result_refs: [%{kind: :chat, text: "已创建页面"}, %{kind: :page, tree: page}]
      })

    {:ok, %{status: :settled}} = dispatch(ctx.session, "turn.settle", %{turn_id: t1})

    snap = wait_for_page(ctx.session, ctx.token, page)
    assert snap.page == page

    {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
    assert surface.approved == v1
  end

  test "SW-UPD: a second turn updates the page; approved advances, old version retained", ctx do
    page_v1 = %{"type" => "services", "props" => %{"title" => "v1"}, "children" => []}
    page_v2 = %{"type" => "services", "props" => %{"title" => "v2 updated"}, "children" => []}

    # 第一版
    {:ok, %{turn_id: t1}} = dispatch(ctx.session, "turn.open", %{trigger: %{message_id: "u1"}, opened_at: 1})
    {:ok, %{version: v1}} = dispatch(ctx.session, "turn.compose", %{turn_id: t1, result_refs: [%{kind: :page, tree: page_v1}]})
    {:ok, _} = dispatch(ctx.session, "turn.settle", %{turn_id: t1})
    wait_for_page(ctx.session, ctx.token, page_v1)

    # 第二版(更新)
    {:ok, %{turn_id: t2}} = dispatch(ctx.session, "turn.open", %{trigger: %{message_id: "u2"}, opened_at: 2})
    {:ok, %{version: v2}} = dispatch(ctx.session, "turn.compose", %{turn_id: t2, result_refs: [%{kind: :page, tree: page_v2}]})
    {:ok, _} = dispatch(ctx.session, "turn.settle", %{turn_id: t2})

    snap = wait_for_page(ctx.session, ctx.token, page_v2)
    assert snap.page == page_v2

    {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
    assert surface.approved == v2
    refute v1 == v2
    # 旧版本仍在(不可变历史)
    assert surface.versions[v1].tree == page_v1
    assert surface.versions[v2].tree == page_v2
  end

  defp dispatch(session_uri, action, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{action}"),
      mode: :call,
      args: args,
      ctx: %{caller: User.admin_uri(), caps: Ezagent.SystemPrincipal.caps("system://bootstrap"), reply: {:caller_inbox, self()}}
    })
  end

  defp wait_for_page(session_uri, token, page, n \\ 200)
  defp wait_for_page(_s, _t, _p, 0), do: flunk("customer feed never served the page")

  defp wait_for_page(session_uri, token, page, n) do
    case CustomerFeed.snapshot(session_uri, token) do
      {:ok, %{page: ^page} = snap} -> snap
      _ -> Process.sleep(20); wait_for_page(session_uri, token, page, n - 1)
    end
  end
end
