defmodule EzagentPluginCrawler.PagePublisherTest do
  @moduledoc """
  段4 D2 unit gate for `EzagentPluginCrawler.PagePublisher` — 把留存线索发布
  成 committed 公开页的 turn-drive（open → compose(page tree + chat) →
  settle，照 hello TurnDriver 的 chokepoint 流，零 LLM、零假数据）。

  经 `:dispatch_fun` seam 捕获三步顺序 `:call` dispatch，断言 page tree 是
  `CrawlerRender.render_tree/1` 的同一投影（真数据行进 compose 的
  result_refs）；任一步失败 → `{:error, _}` + `[:crawler, :page_publish,
  :error]` telemetry（fail-loud）。
  """
  use ExUnit.Case, async: false

  alias EzagentPluginCrawler.PagePublisher

  setup do
    on_exit(fn -> Application.delete_env(:ezagent_plugin_crawler, :dispatch_fun) end)
    :ok
  end

  defp items do
    [
      %{
        "title" => "Show HN: Postgres proxy",
        "url" => "https://example.com/pgp",
        "summary" => "s1",
        "source" => "hn",
        "source_type" => "public",
        "retained_at" => "2026-07-10T00:00:00Z"
      }
    ]
  end

  defp stub_turn_pipeline(test_pid) do
    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd})

      cond do
        URI.to_string(cmd.target) =~ "action=turn.open" -> {:ok, %{turn_id: "t-1"}}
        URI.to_string(cmd.target) =~ "action=turn.compose" -> {:ok, %{status: :composing}}
        URI.to_string(cmd.target) =~ "action=turn.settle" -> {:ok, %{status: :settled}}
      end
    end)
  end

  test "publish_items drives turn.open → compose(chat + page tree) → settle in order" do
    test_pid = self()
    stub_turn_pipeline(test_pid)
    session_uri = Ezagent.URI.new!("session://system/default/pp")

    assert {:ok, "t-1"} = PagePublisher.publish_items(session_uri, items(), "新线索 1 条（crawl）")

    assert_receive {:dispatched, %Ezagent.Invocation{mode: :call} = open_cmd}, 500
    assert URI.to_string(open_cmd.target) =~ "action=turn.open"
    assert open_cmd.args.trigger == %{source: "crawler-page"}

    assert_receive {:dispatched, %Ezagent.Invocation{mode: :call} = compose_cmd}, 500
    assert URI.to_string(compose_cmd.target) =~ "action=turn.compose"
    assert compose_cmd.args.turn_id == "t-1"

    # compose 的 result_refs = chat 摘要 + page 树（真数据：留存线索的同一
    # CrawlerRender 投影——view 与公开页单一投影源）。
    [chat_ref, page_ref] = compose_cmd.args.result_refs
    assert chat_ref == %{kind: :chat, text: "新线索 1 条（crawl）"}
    assert page_ref.kind == :page
    assert page_ref.tree == Ezagent.ActionSet.CrawlerRender.render_tree(items())
    assert inspect(page_ref.tree) =~ "Show HN: Postgres proxy"

    assert_receive {:dispatched, %Ezagent.Invocation{mode: :call} = settle_cmd}, 500
    assert URI.to_string(settle_cmd.target) =~ "action=turn.settle"
    assert settle_cmd.args == %{turn_id: "t-1"}

    refute_receive {:dispatched, _}, 100
  end

  test "空 summary → result_refs 只有 page 树（不发空 chat 行）" do
    test_pid = self()
    stub_turn_pipeline(test_pid)
    session_uri = Ezagent.URI.new!("session://system/default/pp2")

    assert {:ok, _} = PagePublisher.publish_items(session_uri, items(), "")

    assert_receive {:dispatched, _open}, 500
    assert_receive {:dispatched, compose_cmd}, 500
    assert [%{kind: :page}] = compose_cmd.args.result_refs
  end

  test "任一步失败 → {:error, _} + [:crawler, :page_publish, :error] telemetry（fail-loud）" do
    test_pid = self()
    handler_id = "pp-error-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:crawler, :page_publish, :error],
        fn _event, _m, meta, _c -> send(test_pid, {:publish_error, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd ->
      {:error, :unauthorized}
    end)

    session_uri = Ezagent.URI.new!("session://system/default/pp3")
    assert {:error, :unauthorized} = PagePublisher.publish_items(session_uri, items(), "s")
    assert_receive {:publish_error, %{reason: :unauthorized}}, 500
  end

  test "publish/2 with zero retained leads → {:ok, :empty} + :skipped telemetry（不发空页）" do
    test_pid = self()
    handler_id = "pp-skip-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:crawler, :page_publish, :skipped],
        fn _event, _m, meta, _c -> send(test_pid, {:skipped, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd ->
      send(test_pid, :dispatched)
      :ok
    end)

    # 无 live Kind 的 session → items_for 退 []（fail-safe）→ 跳过发布。
    session_uri = Ezagent.URI.session("ws-pp-none", "generic", "empty")
    assert {:ok, :empty} = PagePublisher.publish(session_uri, "s")
    assert_receive {:skipped, _}, 500
    refute_receive :dispatched, 100
  end

  test "publish_async runs under the plugin Task.Supervisor（supervised fire-and-forget）" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd ->
      send(test_pid, :dispatched)
      :ok
    end)

    session_uri = Ezagent.URI.session("ws-pp-async", "generic", "s")
    assert {:ok, pid} = PagePublisher.publish_async(session_uri, "s")
    assert is_pid(pid)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end
end
