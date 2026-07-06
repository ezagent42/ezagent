defmodule EzagentPluginDealScout.DealScoutSearchTest do
  use ExUnit.Case, async: false
  alias Ezagent.ActionSet.DealScoutCrawl

  setup do
    on_exit(fn ->
      for k <- [:fetch_fun, :search_fun, :dispatch_fun],
          do: Application.delete_env(:ezagent_plugin_dealscout, k)
    end)

    :ok
  end

  test "the ActionSet declares both :crawl_now and :search actions + caps" do
    assert Enum.sort(DealScoutCrawl.actions()) == [:crawl_now, :search]
    assert Map.has_key?(DealScoutCrawl.required_caps(), :search)
  end

  test "handle_search dispatches query results tagged as search into the feed" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_dealscout, :search_fun, fn _q ->
      {:ok,
       [
         %{
           title: "早期基金",
           url: "u",
           summary: "s",
           source: "search",
           ts: DateTime.utc_now(),
           source_type: :public
         }
       ]}
    end)

    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}

    assert {:ok, %{injected: 1}, _} =
             DealScoutCrawl.handle_search(%{query: "早期基金", source: "public"}, ctx)

    assert_receive {:dispatched, %Ezagent.Invocation{mode: :cast} = cmd}, 500
    assert cmd.target |> URI.to_string() =~ "action=session.send"
    assert cmd.args.message.body.text =~ "search"

    # 注入后跟一条更新信号（内容协议，routing 的 text_contains 靶子）
    assert_receive {:dispatched, %Ezagent.Invocation{} = signal}, 500
    assert signal.args.message.body.text =~ DealScoutCrawl.update_signal()
  end

  test "an empty search emits no update signal" do
    test_pid = self()
    Application.put_env(:ezagent_plugin_dealscout, :search_fun, fn _q -> {:ok, []} end)

    Application.put_env(:ezagent_plugin_dealscout, :dispatch_fun, fn cmd ->
      send(test_pid, {:dispatched, cmd})
      :ok
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 0}, _} = DealScoutCrawl.handle_search(%{query: "x"}, ctx)
    refute_receive {:dispatched, _}, 100
  end

  test "search_fun receives the query string" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_dealscout, :search_fun, fn q ->
      send(test_pid, {:queried, q})
      {:ok, []}
    end)

    ctx = %{session_uri: Ezagent.URI.new!("session://system/default/t"), caller: nil}
    assert {:ok, %{injected: 0}, _} = DealScoutCrawl.handle_search(%{query: "具身智能"}, ctx)
    assert_receive {:queried, "具身智能"}, 500
  end
end
