defmodule Ezagent.PluginCc.ProviderCatalogTest do
  use ExUnit.Case, async: true
  alias Ezagent.PluginCc.ProviderCatalog

  test "names/0 is the closed sorted set" do
    assert ProviderCatalog.names() == ["deepseek", "kimi", "kimi-coding"]
  end

  test "fetch/1 returns the documented DeepSeek profile (design §2.1)" do
    assert {:ok, p} = ProviderCatalog.fetch("deepseek")
    assert p.base_url == "https://api.deepseek.com/anthropic"
    assert p.api_key_env == "DEEPSEEK_API_KEY"

    assert p.static_env == %{
             "ANTHROPIC_MODEL" => "deepseek-v4-pro[1m]",
             "ANTHROPIC_DEFAULT_OPUS_MODEL" => "deepseek-v4-pro[1m]",
             "ANTHROPIC_DEFAULT_SONNET_MODEL" => "deepseek-v4-pro[1m]",
             "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "deepseek-v4-flash",
             "CLAUDE_CODE_SUBAGENT_MODEL" => "deepseek-v4-flash",
             "CLAUDE_CODE_EFFORT_LEVEL" => "max"
           }
  end

  test "fetch/1 returns the documented Kimi profile (design §2.2)" do
    assert {:ok, p} = ProviderCatalog.fetch("kimi")
    assert p.base_url == "https://api.moonshot.ai/anthropic"
    assert p.api_key_env == "MOONSHOT_API_KEY"

    assert p.static_env == %{
             "ANTHROPIC_MODEL" => "kimi-k3",
             "ANTHROPIC_DEFAULT_OPUS_MODEL" => "kimi-k3",
             "ANTHROPIC_DEFAULT_SONNET_MODEL" => "kimi-k3",
             "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "kimi-k3",
             "CLAUDE_CODE_SUBAGENT_MODEL" => "kimi-k3",
             "ENABLE_TOOL_SEARCH" => "false",
             "CLAUDE_CODE_AUTO_COMPACT_WINDOW" => "1048576"
           }
  end

  test "fetch/1 returns the Kimi for Coding subscription profile (proven 2026-07-18)" do
    assert {:ok, p} = ProviderCatalog.fetch("kimi-coding")
    assert p.base_url == "https://api.kimi.com/coding"
    assert p.api_key_env == "KIMI_CODING_API_KEY"

    assert p.static_env == %{
             "ANTHROPIC_MODEL" => "kimi-k3[1m]",
             "ANTHROPIC_DEFAULT_OPUS_MODEL" => "kimi-k3[1m]",
             "ANTHROPIC_DEFAULT_SONNET_MODEL" => "kimi-k3[1m]",
             "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "kimi-k3[1m]",
             "CLAUDE_CODE_SUBAGENT_MODEL" => "kimi-k3[1m]",
             "ENABLE_TOOL_SEARCH" => "false",
             "CLAUDE_CODE_AUTO_COMPACT_WINDOW" => "1048576"
           }
  end

  test "fetch/1 rejects unknown and non-string names (closed catalog)" do
    assert ProviderCatalog.fetch("openai") == :error
    assert ProviderCatalog.fetch(:deepseek) == :error
    assert ProviderCatalog.fetch(nil) == :error
  end

  test "server-side env-var names live ONLY in the catalog (secret-reference allowlist)" do
    lib = Path.expand("../../../lib", __DIR__)

    offenders =
      Path.wildcard(Path.join(lib, "**/*.ex"))
      |> Enum.reject(&String.ends_with?(&1, "provider_catalog.ex"))
      |> Enum.filter(fn f ->
        src = File.read!(f)

        String.contains?(src, "DEEPSEEK_API_KEY") or String.contains?(src, "MOONSHOT_API_KEY") or
          String.contains?(src, "KIMI_CODING_API_KEY")
      end)

    assert offenders == []
  end
end
