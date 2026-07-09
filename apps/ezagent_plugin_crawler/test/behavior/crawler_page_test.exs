defmodule Ezagent.ActionSet.CrawlerPageTest do
  @moduledoc """
  段4 D2 unit gate for `Ezagent.ActionSet.CrawlerPage` — page 角色槽的
  caller-dispatch 页面发布腿（`:publish_page`）。

  handler 契约：解析 args 里的 `session_uri`（fail-closed：必须是 session://
  实例 URI）→ 经 `:page_publish_fun` seam（默认 supervised-Task 的
  `PagePublisher.publish_async/2`）fire-and-forget 发布；坏 URI 同步
  `{:error, {:bad_session_uri, ...}}` 返回给 dispatch 方（fail-loud）。
  """
  use ExUnit.Case, async: false

  alias Ezagent.ActionSet.CrawlerPage

  setup do
    on_exit(fn -> Application.delete_env(:ezagent_plugin_crawler, :page_publish_fun) end)
    :ok
  end

  test "declares the single dispatchable :publish_page action (caps 形状照 kanban 板动作)" do
    assert CrawlerPage.actions() == [:publish_page]
    # dispatch surface 在场（与 cap-only 的 CrawlerRender interface %{} 相对）。
    assert %{publish_page: _} = CrawlerPage.interface()

    assert %{publish_page: %Ezagent.Capability{action: :publish_page}} =
             CrawlerPage.required_caps()
  end

  test "dispatch 进 handler → 解析 session_uri，带摘要经 seam 触发发布（fire-and-forget）" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_crawler, :page_publish_fun, fn session_uri, summary ->
      send(test_pid, {:publish, session_uri, summary})
      {:ok, self()}
    end)

    args = %{summary: "新线索 3 条（crawl）", session_uri: "session://system/default/t"}
    assert {:ok, %{}, []} = CrawlerPage.handle_publish_page(args, %{})

    assert_receive {:publish, %URI{scheme: "session"} = uri, "新线索 3 条（crawl）"}, 500
    assert URI.to_string(uri) == "session://system/default/t"
  end

  test "空 summary → 缺省发布说明（信号本身就是指令）" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_crawler, :page_publish_fun, fn _uri, summary ->
      send(test_pid, {:summary, summary})
      {:ok, self()}
    end)

    assert {:ok, %{}, []} =
             CrawlerPage.handle_publish_page(
               %{summary: "   ", session_uri: "session://system/default/t"},
               %{}
             )

    assert_receive {:summary, summary}, 500
    assert is_binary(summary) and String.trim(summary) != ""
  end

  test "非 session:// / 畸形 URI → fail-loud {:error, {:bad_session_uri, _}}，不触发发布" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_crawler, :page_publish_fun, fn _uri, _summary ->
      send(test_pid, :published)
      {:ok, self()}
    end)

    assert {:error, {:bad_session_uri, {:not_a_session_uri, _}}} =
             CrawlerPage.handle_publish_page(
               %{summary: "s", session_uri: "entity://demo-ws/agent/discover-1"},
               %{}
             )

    assert {:error, {:bad_session_uri, {:malformed_uri, _}}} =
             CrawlerPage.handle_publish_page(%{summary: "s", session_uri: "not a uri"}, %{})

    refute_receive :published, 100
  end
end
