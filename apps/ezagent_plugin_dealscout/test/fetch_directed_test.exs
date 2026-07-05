defmodule EzagentPluginDealScout.FetchDirectedTest do
  # async: false — token creds + injected http seam via app env (shared).
  use ExUnit.Case, async: false
  alias EzagentPluginDealScout.{Config, Fetch}

  # Canned :httpc.request/4 reply carrying a JSON body, so no real network.
  defp stub_http(body) do
    fn :get, _request, _http_opts, _opts ->
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], body}}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_dealscout, :http_request_fun)
      Config.delete_token("acme")
    end)

    :ok
  end

  describe "fetch_directed/2 (token-gated directed source)" do
    test "with a stored token: injects Bearer header, tags items :directed" do
      :ok = Config.write_token("acme", "tok-xyz")

      Application.put_env(
        :ezagent_plugin_dealscout,
        :http_request_fun,
        stub_http(~s([{"title":"定向线索","url":"u","summary":"s"}]))
      )

      assert {:ok, [item]} = Fetch.fetch_directed("https://acme/api", "acme")
      assert item.source_type == :directed
      assert item.title == "定向线索"
    end

    test "no token is fail-closed: {:error, :no_token}, source explicitly skipped" do
      assert :error = Config.read_token("acme")
      assert {:error, :no_token} = Fetch.fetch_directed("https://acme/api", "acme")
    end
  end

  describe "crawl_auto/1 — the source/token auto-routing decision point (Stage A gap)" do
    test "no configured sources: crawls public only, all items :public" do
      Application.put_env(
        :ezagent_plugin_dealscout,
        :http_request_fun,
        stub_http(~s([{"title":"公开线索","url":"u","summary":"s"}]))
      )

      assert {:ok, items} = Fetch.crawl_auto([])
      assert items != []
      assert Enum.all?(items, &(&1.source_type == :public))
    end

    test "configured source WITH token: yields both :public and :directed items" do
      :ok = Config.write_token("acme", "tok-xyz")

      Application.put_env(
        :ezagent_plugin_dealscout,
        :http_request_fun,
        stub_http(~s([{"title":"线索","url":"u","summary":"s"}]))
      )

      assert {:ok, items} = Fetch.crawl_auto([%{url: "https://acme/api", source: "acme"}])
      types = items |> Enum.map(& &1.source_type) |> Enum.uniq() |> Enum.sort()
      assert types == [:directed, :public]
    end

    test "configured source WITHOUT token: directed fail-closed skipped, public survives" do
      assert :error = Config.read_token("acme")

      Application.put_env(
        :ezagent_plugin_dealscout,
        :http_request_fun,
        stub_http(~s([{"title":"公开线索","url":"u","summary":"s"}]))
      )

      assert {:ok, items} = Fetch.crawl_auto([%{url: "https://acme/api", source: "acme"}])
      assert items != []
      assert Enum.all?(items, &(&1.source_type == :public))
    end
  end
end
