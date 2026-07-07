defmodule EzagentPluginCrawler.PageRefreshAltTest do
  @moduledoc """
  【显式临时 ALT 的单测 —— A①（#1201 ③，hello 暴露 dispatchable rebuild
  action）落地后随 `Ezagent.ActionSet.DealScoutPageRefreshAlt` 一起整体删除。】

  证 ALT v2 caller-dispatch 腿的 handler 侧契约（`:refresh_page`，kanban 板
  动作同款 —— dispatch 按 action 在实例行为集解析直接跑 handler，不经 bridge）：

    * args 带 `summary` + `session_uri`（string）→ 解析出 session %URI{} →
      调 hello 公开生成入口（`:page_refresh_fun` seam 注入 fake generator，
      默认实现是 `&EzagentPluginHello.Generator.start/2`）；
    * `summary` 空 → 用缺省刷新指令（信号本身就是重建指令）；
    * `session_uri` 不是 session:// / 畸形 → fail-loud `{:error, ...}`，不调
      生成入口（同步返回给 dispatch 方，crawl 侧 telemetry 接住）。

  v1 receive 式的"标记即门 / 防自环"测试随 receive 腿一起删了：本 action 只被
  crawl 的显式 dispatch 触发，不再收任何 session 投递。

  纯进程内单测：不起 session/agent Kind、不打 LLM —— 触发链端到端在
  demo_publish_test（conformance）+ 真浏览器 e2e。
  """
  use ExUnit.Case, async: false

  alias Ezagent.ActionSet.DealScoutPageRefreshAlt

  @session_uri_str "session://demo-ws/dealscout/scout1"

  setup do
    parent = self()

    Application.put_env(:ezagent_plugin_crawler, :page_refresh_fun, fn session_uri, text ->
      send(parent, {:page_refresh, session_uri, text})
      {:ok, parent}
    end)

    on_exit(fn -> Application.delete_env(:ezagent_plugin_crawler, :page_refresh_fun) end)
    :ok
  end

  # caller-dispatch 的调用形状：args %{summary, session_uri}（session_uri 走
  # args 显式传 —— 宿主是 agent Kind，ctx.session_uri 派生不出来）。
  defp refresh(args, ctx \\ %{}) do
    DealScoutPageRefreshAlt.handle_refresh_page(args, ctx)
  end

  test "dispatch 进 handler → 解析 session_uri，带摘要调 hello 生成入口（seam 注入的 fake）" do
    args = %{summary: "新线索 3 条（crawl）", session_uri: @session_uri_str}

    assert {:ok, %{}, []} = refresh(args)
    assert_receive {:page_refresh, %URI{} = session_uri, text}
    assert URI.to_string(session_uri) == @session_uri_str
    assert text == "新线索 3 条（crawl）"
  end

  test "summary 为空 → 用缺省刷新指令（信号本身就是重建指令）" do
    assert {:ok, %{}, []} = refresh(%{summary: "  ", session_uri: @session_uri_str})
    assert_receive {:page_refresh, %URI{}, text}
    assert is_binary(text) and String.trim(text) != ""
  end

  test "session_uri 带 ?action= 尾巴 → 归一成 instance URI 再进生成入口" do
    args = %{summary: "x", session_uri: @session_uri_str <> "?action=session.send"}

    assert {:ok, %{}, []} = refresh(args)
    assert_receive {:page_refresh, %URI{} = session_uri, _text}
    assert URI.to_string(session_uri) == @session_uri_str
  end

  test "session_uri 不是 session:// → fail-loud {:error, ...}，不调生成入口" do
    args = %{summary: "x", session_uri: "entity://demo-ws/agent/discover-1"}

    assert {:error, {:bad_session_uri, {:not_a_session_uri, _}}} = refresh(args)
    refute_receive {:page_refresh, _, _}
  end

  test "session_uri 畸形 → fail-loud {:error, ...}，不调生成入口" do
    assert {:error, {:bad_session_uri, _}} = refresh(%{summary: "x", session_uri: "not a uri"})
    refute_receive {:page_refresh, _, _}
  end

  test "action 声明是 dispatchable 的 :refresh_page（v1 的 :receive 已删）" do
    actions = DealScoutPageRefreshAlt.actions()
    assert :refresh_page in actions
    refute :receive in actions
  end

  test "缺省 seam 指向 hello 的公开生成入口 Generator.start/2（A① 落地后整段删）" do
    Application.delete_env(:ezagent_plugin_crawler, :page_refresh_fun)

    default =
      Application.get_env(
        :ezagent_plugin_crawler,
        :page_refresh_fun,
        &EzagentPluginHello.Generator.start/2
      )

    assert default == (&EzagentPluginHello.Generator.start/2)

    # 公开入口签名仍是 start/2（hello 是已声明 dep；ensure_loaded 防懒加载假阴性）。
    assert Code.ensure_loaded?(EzagentPluginHello.Generator)
    assert function_exported?(EzagentPluginHello.Generator, :start, 2)
  end
end
