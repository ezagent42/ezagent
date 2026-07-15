defmodule EzagentPluginCrawler.ConfigTest do
  # async: false — token round-trip writes a real `system://credentials/*.yaml`
  # file through the FsResolver seam (shared FS), so keep it serial.
  use ExUnit.Case, async: false
  alias EzagentPluginCrawler.Config

  describe "config slice effects (profile / keywords)" do
    test "set_profile returns a {:set, :profile, value} slice effect" do
      assert {:set, :profile, %{stage: "seed"}} = Config.set_profile(%{}, %{stage: "seed"})
    end

    test "set_keywords returns a {:set, :keywords, value} slice effect" do
      # 关键词是纯机制数据（任意字符串），测试数据用中性词——业务措辞只住 L2 配置。
      assert {:set, :keywords, ["elixir", "otp"]} =
               Config.set_keywords(%{}, ["elixir", "otp"])
    end
  end

  describe "sources（定向源清单）slice effect + 读回归一" do
    test "set_sources returns a {:set, :sources, list} slice effect (normalized to atom keys)" do
      assert {:set, :sources, [%{url: "https://acme/api", source: "acme"}]} =
               Config.set_sources(%{}, [%{"url" => "https://acme/api", "source" => "acme"}])
    end

    test "set_sources is fail-closed: any malformed entry rejects the WHOLE batch" do
      assert {:error, {:invalid_sources, [%{url: ""}]}} =
               Config.set_sources(%{}, [%{url: "https://ok", source: "ok"}, %{url: ""}])
    end

    test "sources/1 reads the slice back (atom- or string-keyed after snapshot round-trip)" do
      assert Config.sources(%{sources: [%{url: "u", source: "s"}]}) == [%{url: "u", source: "s"}]

      assert Config.sources(%{"sources" => [%{"url" => "u", "source" => "s"}]}) ==
               [%{url: "u", source: "s"}]

      assert Config.sources(%{}) == []
    end

    test "normalize_sources drops malformed entries and tolerates non-list garbage" do
      assert Config.normalize_sources([%{url: "u", source: "s"}, %{url: ""}, "junk"]) ==
               [%{url: "u", source: "s"}]

      assert Config.normalize_sources(nil) == []
      assert Config.normalize_sources("junk") == []
    end
  end

  describe "token creds (system://credentials, fail-closed)" do
    test "write_token then read_token round-trips" do
      on_exit(fn -> Config.delete_token("acme") end)

      assert :ok = Config.write_token("acme", "tok-123")
      assert {:ok, "tok-123"} = Config.read_token("acme")
    end

    test "missing token is fail-closed :error (not a silent empty)" do
      assert :error = Config.read_token("no-such-source-#{System.unique_integer([:positive])}")
    end
  end
end
