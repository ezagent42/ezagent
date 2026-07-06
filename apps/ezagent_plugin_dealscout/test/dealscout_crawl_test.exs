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

    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn _sources -> {:ok, items} end)

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

    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn _sources -> {:ok, items} end)

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
    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn _sources -> {:ok, []} end)

    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd.args.body})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 0}, _} = DealScoutCrawl.handle_crawl_now(%{}, ctx)
    refute_receive {:dispatched, _}, 100
  end

  describe "crawl_auto live wiring (Stage B 尾巴：sources 从 config slice 进分流决策点)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ezagent_plugin_dealscout, :http_request_fun)
        EzagentPluginDealScout.Config.delete_token("acme")
      end)

      :ok
    end

    test "crawl_now hands the config-slice sources to the crawl seam (normalized)" do
      test_pid = self()

      Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn sources ->
        send(test_pid, {:crawl_sources, sources})
        {:ok, []}
      end)

      Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn _cmd -> :ok end)

      # slice 经 snapshot round-trip 后可能是 string-keyed —— 归一后进 seam。
      ctx = ctx_with_sources([%{"url" => "https://acme/api", "source" => "acme"}])
      assert {:ok, %{injected: 0}, _} = DealScoutCrawl.handle_crawl_now(%{}, ctx)
      assert_receive {:crawl_sources, [%{url: "https://acme/api", source: "acme"}]}, 500
    end

    test "no :read in ctx (or no configured sources) → the seam gets [] (pure public)" do
      test_pid = self()

      Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn sources ->
        send(test_pid, {:crawl_sources, sources})
        {:ok, []}
      end)

      Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn _cmd -> :ok end)

      ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
      assert {:ok, %{injected: 0}, _} = DealScoutCrawl.handle_crawl_now(%{}, ctx)
      assert_receive {:crawl_sources, []}, 500

      assert {:ok, %{injected: 0}, _} = DealScoutCrawl.handle_crawl_now(%{}, ctx_with_sources([]))
      assert_receive {:crawl_sources, []}, 500
    end

    test "REAL path: configured source WITH token → directed branch injects [directed] items" do
      test_pid = self()

      # 不 stub :fetch_fun —— 走真 `Fetch.crawl_auto/1`，只 stub 底层 HTTP +
      # 写真 token 凭证：证明 slice sources → crawl_auto → fetch_directed 的
      # 分流接线真的生效（不是 seam 假装）。
      :ok = EzagentPluginDealScout.Config.write_token("acme", "tok-xyz")

      Application.put_env(:ezagent_plugin_dealscout, :http_request_fun, fn :get,
                                                                           _request,
                                                                           _http_opts,
                                                                           _opts ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s([{"title":"线索","url":"u","summary":"s"}])}}
      end)

      Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd ->
        send(test_pid, {:dispatched, cmd.args.body})
        :ok
      end)

      ctx = ctx_with_sources([%{url: "https://acme/api", source: "acme"}])
      assert {:ok, %{injected: 2}, _} = DealScoutCrawl.handle_crawl_now(%{}, ctx)

      # 公开 + 定向各一条，最后一条更新信号。
      assert_receive {:dispatched, body1}, 500
      assert_receive {:dispatched, body2}, 500
      assert_receive {:dispatched, signal_body}, 500
      bodies = [body1, body2]
      assert Enum.any?(bodies, &String.starts_with?(&1, "[public]"))
      assert Enum.any?(bodies, &String.starts_with?(&1, "[directed]"))
      assert signal_body =~ DealScoutCrawl.update_signal()
    end

    test "REAL path: no configured sources → pure public (no [directed] item)" do
      test_pid = self()

      Application.put_env(:ezagent_plugin_dealscout, :http_request_fun, fn :get,
                                                                           _request,
                                                                           _http_opts,
                                                                           _opts ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s([{"title":"公开","url":"u","summary":"s"}])}}
      end)

      Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd ->
        send(test_pid, {:dispatched, cmd.args.body})
        :ok
      end)

      ctx = ctx_with_sources([])
      assert {:ok, %{injected: 1}, _} = DealScoutCrawl.handle_crawl_now(%{}, ctx)

      assert_receive {:dispatched, body}, 500
      assert String.starts_with?(body, "[public]")
      assert_receive {:dispatched, signal_body}, 500
      assert signal_body =~ DealScoutCrawl.update_signal()
      refute_receive {:dispatched, _}, 100
    end
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

    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn _sources -> {:ok, items} end)
    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn _cmd -> {:error, :nope} end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 0}, _effects} = DealScoutCrawl.handle_crawl_now(%{}, ctx)
  end

  # framework 注入的 slice reader（kb.ex `ctx[:read]` 同款契约）：handler 从
  # :sources key 读定向源清单。（module 级 helper —— describe 块内不能 defp。）
  defp ctx_with_sources(sources) do
    %{
      session_uri: Ezagent.URI.new!("session://system/default/t"),
      caller: nil,
      read: fn
        :sources, _default -> sources
        _key, default -> default
      end
    }
  end
end
