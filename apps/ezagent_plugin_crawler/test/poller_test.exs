defmodule EzagentPluginCrawler.PollerTest do
  use ExUnit.Case, async: false
  alias EzagentPluginCrawler.Poller

  setup do
    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_crawler, :fetch_fun)
      Application.delete_env(:ezagent_plugin_crawler, :sources)
    end)

    :ok
  end

  test "poll_once invokes the configured fetch_fun exactly once (default: no sources → [])" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn sources ->
      send(test_pid, {:fetched, sources})
      {:ok, []}
    end)

    assert :ok = Poller.poll_once()
    assert_receive {:fetched, []}, 500
  end

  test "poll_once feeds the operator app-env :sources into the crawl_auto seam (normalized)" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_crawler, :sources, [
      # string-keyed（config 文件常态）+ 一条坏条目（归一丢弃，不 crash timer）
      %{"url" => "https://acme/api", "source" => "acme"},
      %{"url" => ""}
    ])

    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn sources ->
      send(test_pid, {:fetched, sources})
      {:ok, []}
    end)

    assert :ok = Poller.poll_once()
    assert_receive {:fetched, [%{url: "https://acme/api", source: "acme"}]}, 500
  end

  test "poll_once swallows a recoverable fetch error and returns :ok" do
    Application.put_env(:ezagent_plugin_crawler, :fetch_fun, fn _sources ->
      {:error, :boom}
    end)

    assert :ok = Poller.poll_once()
  end
end
