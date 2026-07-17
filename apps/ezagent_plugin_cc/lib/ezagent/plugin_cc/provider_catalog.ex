defmodule Ezagent.PluginCc.ProviderCatalog do
  @moduledoc """
  Closed, server-owned provider-profile catalog for the cc completion-backend
  dimension (design 2026-07-17 §4.1).

  A profile is DATA: the vendor's documented Claude Code env block minus the
  secret, plus the NAME of the server-side env var the deploy sets. Template
  data may only NAME a profile (`"provider" => "deepseek"`); it can never
  name an env var, URL, or model — the closed catalog is the allowlist
  (locked decision #7). Adding a vendor = adding one entry here + tests; no
  new module/flavor.

  Values track the vendors' current Claude Code guides (design §2, accessed
  2026-07-17). A deploy may retarget endpoint/model tiers without a code
  change via:

      config :ezagent_plugin_cc, :provider_profile_overrides, %{
        "deepseek" => %{base_url: "...", static_env: %{"ANTHROPIC_MODEL" => "..."}}
      }
  """

  @profiles %{
    "deepseek" => %{
      base_url: "https://api.deepseek.com/anthropic",
      api_key_env: "DEEPSEEK_API_KEY",
      static_env: %{
        "ANTHROPIC_MODEL" => "deepseek-v4-pro[1m]",
        "ANTHROPIC_DEFAULT_OPUS_MODEL" => "deepseek-v4-pro[1m]",
        "ANTHROPIC_DEFAULT_SONNET_MODEL" => "deepseek-v4-pro[1m]",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "deepseek-v4-flash",
        "CLAUDE_CODE_SUBAGENT_MODEL" => "deepseek-v4-flash",
        "CLAUDE_CODE_EFFORT_LEVEL" => "max"
      }
    },
    "kimi" => %{
      base_url: "https://api.moonshot.ai/anthropic",
      api_key_env: "MOONSHOT_API_KEY",
      static_env: %{
        "ANTHROPIC_MODEL" => "kimi-k3",
        "ANTHROPIC_DEFAULT_OPUS_MODEL" => "kimi-k3",
        "ANTHROPIC_DEFAULT_SONNET_MODEL" => "kimi-k3",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "kimi-k3",
        "CLAUDE_CODE_SUBAGENT_MODEL" => "kimi-k3",
        "ENABLE_TOOL_SEARCH" => "false",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW" => "1048576"
      }
    },
    # Kimi for Coding SUBSCRIPTION (kimi.com) — a first-party Moonshot product
    # separate from the open platform: platform keys 401 here and subscription
    # keys 401 there (verified 2026-07-18). Empirically proven values:
    # POST {base}/v1/messages → 200, and a real `claude` turn with this exact
    # block (design §2.4 local probe).
    "kimi-coding" => %{
      base_url: "https://api.kimi.com/coding",
      api_key_env: "KIMI_CODING_API_KEY",
      static_env: %{
        "ANTHROPIC_MODEL" => "kimi-k3[1m]",
        "ANTHROPIC_DEFAULT_OPUS_MODEL" => "kimi-k3[1m]",
        "ANTHROPIC_DEFAULT_SONNET_MODEL" => "kimi-k3[1m]",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "kimi-k3[1m]",
        "CLAUDE_CODE_SUBAGENT_MODEL" => "kimi-k3[1m]",
        "ENABLE_TOOL_SEARCH" => "false",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW" => "1048576"
      }
    }
  }

  @type profile :: %{
          base_url: String.t(),
          api_key_env: String.t(),
          static_env: %{String.t() => String.t()}
        }

  @doc "The closed set of profile names, sorted."
  @spec names() :: [String.t()]
  def names, do: @profiles |> Map.keys() |> Enum.sort()

  @doc "`{:ok, profile}` for a catalog name (with deploy overrides applied), else `:error`."
  @spec fetch(term()) :: {:ok, profile()} | :error
  def fetch(name) when is_binary(name) do
    with {:ok, profile} <- Map.fetch(@profiles, name) do
      {:ok, apply_overrides(name, profile)}
    end
  end

  def fetch(_), do: :error

  @doc "True iff `name` is in the closed catalog."
  @spec known?(term()) :: boolean()
  def known?(name), do: match?({:ok, _}, fetch(name))

  defp apply_overrides(name, profile) do
    overrides = Application.get_env(:ezagent_plugin_cc, :provider_profile_overrides, %{})

    case Map.get(overrides, name) do
      nil -> profile
      ov when is_map(ov) -> Map.merge(profile, ov)
    end
  end
end
