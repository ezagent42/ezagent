defmodule EzagentPluginDealScout.PollerTest do
  use ExUnit.Case, async: false
  alias EzagentPluginDealScout.Poller

  test "poll_once invokes the configured fetch_fun exactly once" do
    test_pid = self()

    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn ->
      send(test_pid, :fetched)
      {:ok, []}
    end)

    on_exit(fn -> Application.delete_env(:ezagent_plugin_dealscout, :fetch_fun) end)

    assert :ok = Poller.poll_once()
    assert_receive :fetched, 500
  end

  test "poll_once swallows a recoverable fetch error and returns :ok" do
    Application.put_env(:ezagent_plugin_dealscout, :fetch_fun, fn -> {:error, :boom} end)
    on_exit(fn -> Application.delete_env(:ezagent_plugin_dealscout, :fetch_fun) end)

    assert :ok = Poller.poll_once()
  end
end
