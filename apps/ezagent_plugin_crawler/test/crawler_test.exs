defmodule EzagentPluginCrawler.CrawlerTest do
  use ExUnit.Case, async: false
  alias Ezagent.ActionSet.Crawler

  setup do
    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_crawler, :fetch_fun)
      Application.delete_env(:ezagent_plugin_crawler, :dispatch_fun)
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

    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, items} end)

    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 1}, _effects} = Crawler.handle_crawl_now(%{}, ctx)
    assert_receive {:dispatched, %Ezagent.Invocation{mode: :cast} = cmd}, 500
    assert cmd.target |> URI.to_string() =~ "action=session.send"
  end

  # 2026-07-07 真浏览器 e2e 修正：内层 session.send 必须以触发者身份 dispatch
  # （裸 %{reply: :ignore} 无 caller/caps → Kind authz :unauthorized，线索静默进不了会话）。
  test "inject delegates the OUTER caller/caps into the inner session.send ctx (CapBAC-honest)" do
    test_pid = self()

    items = [
      %{
        title: "t",
        url: "u",
        summary: "s",
        source: "hn",
        ts: DateTime.utc_now(),
        source_type: :public
      }
    ]

    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, items} end)

    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd})
      :ok
    end)

    caller = Ezagent.URI.new!("entity://system/user/admin")
    caps = MapSet.new([:fake_cap])

    ctx = %{
      session_uri: Ezagent.URI.new!("session://system/default/t"),
      caller: caller,
      caps: caps
    }

    assert {:ok, %{injected: 1}, _} = Crawler.handle_crawl_now(%{}, ctx)

    # 线索注入 + 更新信号两条都带触发者身份
    assert_receive {:dispatched, %Ezagent.Invocation{ctx: inject_ctx}}, 500
    assert inject_ctx.caller == caller
    assert inject_ctx.caps == caps
    assert_receive {:dispatched, %Ezagent.Invocation{ctx: signal_ctx}}, 500
    assert signal_ctx.caller == caller
    assert signal_ctx.caps == caps
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

    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, items} end)

    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd.args.message.body.text})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 2}, _} = Crawler.handle_crawl_now(%{}, ctx)

    # 两条线索 + 最后一条更新信号（像 kanban 的 __done__，零实例 URI）
    assert_receive {:dispatched, body1}, 500
    assert_receive {:dispatched, body2}, 500
    assert_receive {:dispatched, signal_body}, 500
    refute_receive {:dispatched, _}, 100

    refute body1 =~ Crawler.update_signal()
    refute body2 =~ Crawler.update_signal()
    assert signal_body =~ Crawler.update_signal()
    assert Crawler.update_signal() == "__dealscout_update__"
    # 内容协议：信号 body 不带任何实例 URI
    refute signal_body =~ "entity://"
    refute signal_body =~ "session://"
  end

  test "no update signal when nothing new was injected (empty crawl)" do
    test_pid = self()
    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, []} end)

    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd.args.message.body.text})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 0}, _} = Crawler.handle_crawl_now(%{}, ctx)
    refute_receive {:dispatched, _}, 100
  end

  describe "crawl_auto live wiring (Stage B 尾巴：sources 从 config slice 进分流决策点)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ezagent_plugin_crawler, :http_request_fun)
        EzagentPluginCrawler.Config.delete_token("acme")
      end)

      :ok
    end

    test "crawl_now hands the config-slice sources to the crawl seam (normalized)" do
      test_pid = self()

      Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn sources ->
        send(test_pid, {:crawl_sources, sources})
        {:ok, []}
      end)

      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd -> :ok end)

      # slice 经 snapshot round-trip 后可能是 string-keyed —— 归一后进 seam。
      ctx = ctx_with_sources([%{"url" => "https://acme/api", "source" => "acme"}])
      assert {:ok, %{injected: 0}, _} = Crawler.handle_crawl_now(%{}, ctx)
      assert_receive {:crawl_sources, [%{url: "https://acme/api", source: "acme"}]}, 500
    end

    test "no :read in ctx (or no configured sources) → the seam gets [] (pure public)" do
      test_pid = self()

      Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn sources ->
        send(test_pid, {:crawl_sources, sources})
        {:ok, []}
      end)

      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd -> :ok end)

      ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
      assert {:ok, %{injected: 0}, _} = Crawler.handle_crawl_now(%{}, ctx)
      assert_receive {:crawl_sources, []}, 500

      assert {:ok, %{injected: 0}, _} = Crawler.handle_crawl_now(%{}, ctx_with_sources([]))
      assert_receive {:crawl_sources, []}, 500
    end

    test "REAL path: configured source WITH token → directed branch injects [directed] items" do
      test_pid = self()

      # 不 stub :fetch_fun —— 走真 `Fetch.crawl_auto/1`，只 stub 底层 HTTP +
      # 写真 token 凭证：证明 slice sources → crawl_auto → fetch_directed 的
      # 分流接线真的生效（不是 seam 假装）。
      :ok = EzagentPluginCrawler.Config.write_token("acme", "tok-xyz")

      Application.put_env(:ezagent_plugin_crawler, :http_request_fun, fn :get,
                                                                         _request,
                                                                         _http_opts,
                                                                         _opts ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s([{"title":"线索","url":"u","summary":"s"}])}}
      end)

      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
        send(test_pid, {:dispatched, cmd.args.message.body.text})
        :ok
      end)

      ctx = ctx_with_sources([%{url: "https://acme/api", source: "acme"}])
      assert {:ok, %{injected: 2}, _} = Crawler.handle_crawl_now(%{}, ctx)

      # 公开 + 定向各一条，最后一条更新信号。
      assert_receive {:dispatched, body1}, 500
      assert_receive {:dispatched, body2}, 500
      assert_receive {:dispatched, signal_body}, 500
      bodies = [body1, body2]
      assert Enum.any?(bodies, &String.starts_with?(&1, "[public]"))
      assert Enum.any?(bodies, &String.starts_with?(&1, "[directed]"))
      assert signal_body =~ Crawler.update_signal()
    end

    test "REAL path: no configured sources → pure public (no [directed] item)" do
      test_pid = self()

      Application.put_env(:ezagent_plugin_crawler, :http_request_fun, fn :get,
                                                                         _request,
                                                                         _http_opts,
                                                                         _opts ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s([{"title":"公开","url":"u","summary":"s"}])}}
      end)

      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
        send(test_pid, {:dispatched, cmd.args.message.body.text})
        :ok
      end)

      ctx = ctx_with_sources([])
      assert {:ok, %{injected: 1}, _} = Crawler.handle_crawl_now(%{}, ctx)

      assert_receive {:dispatched, body}, 500
      assert String.starts_with?(body, "[public]")
      assert_receive {:dispatched, signal_body}, 500
      assert signal_body =~ Crawler.update_signal()
      refute_receive {:dispatched, _}, 100
    end
  end

  describe "页面发布的直接 dispatch 腿（v2 caller-dispatch，绕 #1201 ②）" do
    test "injected>0 且 siblings 里有 page 成员 → 直接 dispatch :publish_page（:call，带 summary + session_uri，透传触发者身份）" do
      test_pid = self()

      items = [
        %{
          title: "t",
          url: "u",
          summary: "s",
          source: "hn",
          ts: DateTime.utc_now(),
          source_type: :public
        }
      ]

      Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, items} end)

      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
        send(test_pid, {:dispatched, cmd})
        :ok
      end)

      caller = Ezagent.URI.new!("entity://system/user/admin")
      caps = MapSet.new([:fake_cap])
      page_uri = Ezagent.URI.new!("entity://system/agent/page-1")
      ctx = ctx_with_page_member(page_uri, caller: caller, caps: caps)

      assert {:ok, %{injected: 1}, _} = Crawler.handle_crawl_now(%{}, ctx)

      # 线索注入 → 更新信号（chat 腿保留）→ 直接 dispatch 腿，三条按序。
      assert_receive {:dispatched, %Ezagent.Invocation{} = _inject_cmd}, 500
      assert_receive {:dispatched, %Ezagent.Invocation{} = _signal_cmd}, 500
      assert_receive {:dispatched, %Ezagent.Invocation{mode: :call} = publish_cmd}, 500

      target = URI.to_string(publish_cmd.target)
      assert target =~ "entity://system/agent/page-1"
      assert target =~ "action=crawler_page.publish_page"

      assert publish_cmd.args.summary =~ "新线索 1 条（crawl）"
      assert publish_cmd.args.session_uri == "session://system/default/t"
      # CapBAC-honest：以触发者身份 dispatch（触发者没 cap 就被拒）。
      assert publish_cmd.ctx.caller == caller
      assert publish_cmd.ctx.caps == caps
    end

    test "没有 page 成员 → fail-loud telemetry，不发 publish dispatch（不静默）" do
      test_pid = self()
      handler_id = "crawler-page-publish-error-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:crawler, :page_publish, :error],
          fn _event, _measurements, meta, _config ->
            send(test_pid, {:page_publish_error, meta})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      items = [
        %{
          title: "t",
          url: "u",
          summary: "s",
          source: "hn",
          ts: DateTime.utc_now(),
          source_type: :public
        }
      ]

      Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, items} end)

      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn cmd ->
        send(test_pid, {:dispatched, cmd})
        :ok
      end)

      # siblings 里 session slice 可读、但没人持 page role_name。
      ctx = %{
        session_uri: Ezagent.URI.new!("session://system/default/t"),
        caller: nil,
        siblings: %{session: %{members: %{}}}
      }

      assert {:ok, %{injected: 1}, _} = Crawler.handle_crawl_now(%{}, ctx)

      assert_receive {:page_publish_error, %{reason: :no_page_member, injected: 1}}, 500

      # 只有线索注入 + 更新信号两条，没有 publish dispatch。
      assert_receive {:dispatched, _}, 500
      assert_receive {:dispatched, _}, 500
      refute_receive {:dispatched, _}, 100
    end

    test "injected == 0 → 不发 publish、不报错（与更新信号同门）" do
      test_pid = self()
      handler_id = "crawler-page-publish-error-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:crawler, :page_publish, :error],
          fn _event, _measurements, meta, _config ->
            send(test_pid, {:page_publish_error, meta})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, []} end)
      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd -> :ok end)

      ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
      assert {:ok, %{injected: 0}, _} = Crawler.handle_crawl_now(%{}, ctx)
      refute_receive {:page_publish_error, _}, 100
    end

    test "page_role/0 是单一契约点（manifest 的角色槽声明用同一个名字）" do
      assert Crawler.page_role() == "page"
    end
  end

  describe "结构化线索留存（段4 D2：注入成功的线索经 {:set, :items, ...} 落 slice）" do
    defp fixture_item(n) do
      %{
        title: "线索#{n}",
        url: "https://example.com/#{n}",
        summary: "s#{n}",
        source: "hn",
        ts: ~U[2026-07-10 00:00:00Z],
        source_type: :public
      }
    end

    test "crawl_now retains injected leads as string-keyed JSON-safe entries (newest first)" do
      Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources ->
        {:ok, [fixture_item(1), fixture_item(2)]}
      end)

      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd -> :ok end)

      ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
      assert {:ok, %{injected: 2}, effects} = Crawler.handle_crawl_now(%{}, ctx)

      assert [{:set, :items, retained}] = effects
      assert Enum.map(retained, & &1["title"]) == ["线索1", "线索2"]

      # JSON round-trip 安全（slice 随 snapshot 序列化）：string key、纯字符串值。
      assert Jason.encode!(retained)

      assert [%{"source_type" => "public", "retained_at" => "2026-07-10T00:00:00Z"} | _] =
               retained
    end

    test "retention merges with existing slice items, dedupes by url+title, caps the length" do
      Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources ->
        {:ok, [fixture_item(1), fixture_item(2)]}
      end)

      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd -> :ok end)

      existing =
        [
          # 与本轮线索1 同 url+title —— 必须去重（新条目在前）。
          %{"title" => "线索1", "url" => "https://example.com/1", "summary" => "old"}
        ] ++
          for n <- 3..(Crawler.max_retained_items() + 5) do
            %{"title" => "旧#{n}", "url" => "https://old.example/#{n}", "summary" => ""}
          end

      ctx = %{
        session_uri: Ezagent.URI.new!("session://system/default/t"),
        caller: nil,
        read: fn
          :items, _default -> existing
          _key, default -> default
        end
      }

      assert {:ok, %{injected: 2}, [{:set, :items, retained}]} =
               Crawler.handle_crawl_now(%{}, ctx)

      # 新条目在前，同 url+title 的旧条目被去重掉，总长封顶。
      assert ["线索1", "线索2" | _] = Enum.map(retained, & &1["title"])
      assert Enum.count(retained, &(&1["title"] == "线索1")) == 1
      assert length(retained) == Crawler.max_retained_items()
    end

    test "empty crawl / zero injected → zero effects (slice untouched)" do
      Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, []} end)
      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd -> :ok end)

      ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
      assert {:ok, %{injected: 0}, []} = Crawler.handle_crawl_now(%{}, ctx)
    end

    test "search retains its injected leads too (source tagged search:<source>)" do
      Application.put_env(:ezagent_plugin_crawler, :search_fun, fn _query ->
        {:ok, [fixture_item(9)]}
      end)

      on_exit(fn -> Application.delete_env(:ezagent_plugin_crawler, :search_fun) end)
      Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd -> :ok end)

      ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}

      assert {:ok, %{injected: 1}, [{:set, :items, [entry]}]} =
               Crawler.handle_search(%{query: "postgres", source: "hn"}, ctx)

      assert entry["title"] == "线索9"
      assert entry["source"] == "search:hn"
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

    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources -> {:ok, items} end)
    Application.put_env(:ezagent_plugin_crawler, :dispatch_fun, fn _cmd -> {:error, :nope} end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 0}, _effects} = Crawler.handle_crawl_now(%{}, ctx)
  end

  # 直接 dispatch 腿的 ctx：runtime 注入的 `ctx.siblings`（`reads_siblings
  # [:session]`）里带 session slice 的 members map（%URI{} key + role_name
  # facet —— `Session.Members.role_name_to_uri/2` 的输入形状）。
  defp ctx_with_page_member(page_uri, opts) do
    %{
      session_uri: Ezagent.URI.new!("session://system/default/t"),
      caller: Keyword.get(opts, :caller),
      caps: Keyword.get(opts, :caps),
      siblings: %{
        session: %{
          members: %{page_uri => %{role_name: Crawler.page_role()}}
        }
      }
    }
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
