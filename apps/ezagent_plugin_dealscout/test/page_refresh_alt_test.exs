defmodule EzagentPluginDealScout.PageRefreshAltTest do
  @moduledoc """
  【显式临时 ALT 的单测 —— A①（#1201 ③）落地后随
  `Ezagent.ActionSet.DealScoutPageRefreshAlt` 一起整体删除。】

  证 ALT 闭环腿的收信侧契约（session 投递 fan-out 的 `:receive`，与
  `Ezagent.ActionSet.HelloBuilder` 同一投递形状）：

    * 带 `__dealscout_update__` 标记的 agent 消息 → 提取爬取摘要文本 → 调
      hello 公开生成入口（`:page_refresh_fun` seam 注入 fake generator，
      默认实现是 `&EzagentPluginHello.Generator.start/2`）；
    * 不带标记的消息（用户聊天 / 注入的线索条目 / builder narration）一律
      不触发（标记即门，防自环）。

  纯进程内单测：不起 session/agent Kind、不打 LLM —— fan-out 端到端在
  demo_publish_test（conformance）+ Stage E 的真浏览器 e2e。
  """
  use ExUnit.Case, async: false

  alias Ezagent.ActionSet.{DealScoutCrawl, DealScoutPageRefreshAlt}
  alias Ezagent.Message

  @session_uri Ezagent.URI.new!("session://demo-ws/dealscout/scout1")
  @agent_sender Ezagent.URI.new!("entity://demo-ws/agent/discover-1")
  @user_sender Ezagent.URI.new!("entity://demo-ws/user/alice")

  setup do
    parent = self()

    Application.put_env(:ezagent_plugin_dealscout, :page_refresh_fun, fn session_uri, text ->
      send(parent, {:page_refresh, session_uri, text})
      {:ok, parent}
    end)

    on_exit(fn -> Application.delete_env(:ezagent_plugin_dealscout, :page_refresh_fun) end)
    :ok
  end

  # session 投递 fan-out 的调用形状（`Session.Delivery.dispatch_receive_call/3`）：
  # args %{message: %Message{}}，ctx.caller = 发起 session 的 %URI{}。
  defp deliver(msg, ctx \\ %{caller: @session_uri}) do
    DealScoutPageRefreshAlt.handle_receive(%{message: msg}, ctx)
  end

  test "更新信号 → 提取爬取摘要文本，调 hello 生成入口（seam 注入的 fake）" do
    body = "#{DealScoutCrawl.update_signal()} 新线索 3 条（crawl）"
    msg = Message.new(@agent_sender, %{text: body})

    assert {:ok, %{}, []} = deliver(msg)
    assert_receive {:page_refresh, session_uri, text}
    assert session_uri == @session_uri
    # 标记剥掉，只剩摘要（生成 prompt 的语境）。
    assert text == "新线索 3 条（crawl）"
    refute String.contains?(text, DealScoutCrawl.update_signal())
  end

  test "裸标记（剥完为空）也触发重建，用缺省刷新指令" do
    msg = Message.new(@agent_sender, %{text: DealScoutCrawl.update_signal()})

    assert {:ok, %{}, []} = deliver(msg)
    assert_receive {:page_refresh, @session_uri, text}
    assert is_binary(text) and text != ""
  end

  test "不带标记的消息不触发（用户聊天 / 线索条目 / narration —— 标记即门，防自环）" do
    for {sender, text} <- [
          {@user_sender, "帮我做一个线索页"},
          {@agent_sender, "[hn] Some Startup — raised a round (https://example.com)"},
          {@agent_sender, "Done! Page \"Deals\" generated."}
        ] do
      msg = Message.new(sender, %{text: text})
      assert {:ok, %{}, []} = deliver(msg)
    end

    refute_receive {:page_refresh, _, _}
  end

  test "ctx 无 session caller（防御分支）→ 不调生成入口，仍正常返回" do
    body = "#{DealScoutCrawl.update_signal()} 新线索 1 条（search）"
    msg = Message.new(@agent_sender, %{text: body})

    assert {:ok, %{}, []} = deliver(msg, %{})
    refute_receive {:page_refresh, _, _}
  end

  test "缺省 seam 指向 hello 的公开生成入口 Generator.start/2（A① 落地后整段删）" do
    Application.delete_env(:ezagent_plugin_dealscout, :page_refresh_fun)

    default =
      Application.get_env(
        :ezagent_plugin_dealscout,
        :page_refresh_fun,
        &EzagentPluginHello.Generator.start/2
      )

    assert default == (&EzagentPluginHello.Generator.start/2)
    # 公开入口签名仍是 start/2（hello 是已声明 dep；ensure_loaded 防懒加载假阴性）。
    assert Code.ensure_loaded?(EzagentPluginHello.Generator)
    assert function_exported?(EzagentPluginHello.Generator, :start, 2)
  end
end
