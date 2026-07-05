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
