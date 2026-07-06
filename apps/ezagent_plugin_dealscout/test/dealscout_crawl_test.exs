defmodule EzagentPluginDealScout.DealScoutCrawlTest do
  use ExUnit.Case, async: false
  alias Ezagent.ActionSet.DealScoutCrawl

  setup do
    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_dealscout, :fetch_fun)
      Application.delete_env(:ezagent_plugin_dealscout, :dispatch_fun)
    end)

    :ok
  end

  test "crawl_now dispatches one session.send per fetched item via the injected seam" do
    test_pid = self()

    items = [
      %{
        title: "某基金",
        url: "u",
        summary: "s",
        source: "hn",
        ts: DateTime.utc_now(),
        source_type: :public
      }
    ]

    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn -> {:ok, items} end)

    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 1}, _effects} = DealScoutCrawl.handle_crawl_now(%{}, ctx)
    assert_receive {:dispatched, %Ezagent.Invocation{mode: :cast} = cmd}, 500
    assert cmd.target |> URI.to_string() =~ "action=session.send"
  end

  test "crawl_now with new leads emits ONE update signal after the items (content protocol)" do
    test_pid = self()

    items =
      for n <- 1..2 do
        %{
          title: "线索#{n}",
          url: "u#{n}",
          summary: "s",
          source: "hn",
          ts: DateTime.utc_now(),
          source_type: :public
        }
      end

    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn -> {:ok, items} end)

    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd.args.body})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 2}, _} = DealScoutCrawl.handle_crawl_now(%{}, ctx)

    # 两条线索 + 最后一条更新信号（像 kanban 的 __done__，零实例 URI）
    assert_receive {:dispatched, body1}, 500
    assert_receive {:dispatched, body2}, 500
    assert_receive {:dispatched, signal_body}, 500
    refute_receive {:dispatched, _}, 100

    refute body1 =~ DealScoutCrawl.update_signal()
    refute body2 =~ DealScoutCrawl.update_signal()
    assert signal_body =~ DealScoutCrawl.update_signal()
    assert DealScoutCrawl.update_signal() == "__dealscout_update__"
    # 内容协议：信号 body 不带任何实例 URI
    refute signal_body =~ "entity://"
    refute signal_body =~ "session://"
  end

  test "no update signal when nothing new was injected (empty crawl)" do
    test_pid = self()
    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn -> {:ok, []} end)

    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd.args.body})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 0}, _} = DealScoutCrawl.handle_crawl_now(%{}, ctx)
    refute_receive {:dispatched, _}, 100
  end

  test "a failed dispatch is counted out (fail-loud, not silent) — injected stays 0" do
    items = [
      %{
        title: "x",
        url: "u",
        summary: "s",
        source: "hn",
        ts: DateTime.utc_now(),
        source_type: :directed
      }
    ]

    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn -> {:ok, items} end)
    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn _cmd -> {:error, :nope} end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 0}, _effects} = DealScoutCrawl.handle_crawl_now(%{}, ctx)
  end
end
