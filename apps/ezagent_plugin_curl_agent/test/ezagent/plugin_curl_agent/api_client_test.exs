defmodule Ezagent.PluginCurlAgent.ApiClientTest do
  use ExUnit.Case, async: false

  alias Ezagent.PluginCurlAgent.ApiClient

  setup do
    original = Application.get_env(:ezagent_plugin_curl_agent, :receive_timeout)

    on_exit(fn ->
      if original == nil do
        Application.delete_env(:ezagent_plugin_curl_agent, :receive_timeout)
      else
        Application.put_env(:ezagent_plugin_curl_agent, :receive_timeout, original)
      end
    end)

    :ok
  end

  test "waits indefinitely for a non-streaming response by default" do
    Application.delete_env(:ezagent_plugin_curl_agent, :receive_timeout)

    assert ApiClient.receive_timeout(%{}) == :infinity
  end

  test "supports finite application and per-request timeout overrides" do
    Application.put_env(:ezagent_plugin_curl_agent, :receive_timeout, 90_000)

    assert ApiClient.receive_timeout(%{}) == 90_000
    assert ApiClient.receive_timeout(%{receive_timeout: 45_000}) == 45_000
    assert ApiClient.receive_timeout(%{receive_timeout: :infinity}) == :infinity
  end
end
