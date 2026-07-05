defmodule EzagentPluginDealScout.Application do
  @moduledoc """
  dealscout socialware plugin — the `Ezagent.Plugin` contract module.

  DealScout = 商业 / 投融资线索的搜索与撮合平台（deal 侦察兵）。两条腿：
  **发现腿（地基·本 Stage A）**——AI 千人千面主动发现 + 主动搜索 + 爬取 + 深挖追问；
  **撮合腿（后续 Stage）**——组合 hello 拿公开面 + concierge 客服。

  ## Plugin authoring contract

  Per the plugin authoring contract the OTP `Application` module IS the plugin
  contract module: it `use`s both `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot/1`, which starts `children/0` FIRST then publishes every
  declaration — the author never touches a `*Registry` API. The
  `:ezagent_plugin_check` Mix compiler is the non-bypassable gate.

  ## Stage A scaffold (this stage)

  Only `plugin_info/0` + `children/0` are declared — a minimal, compilable,
  gate-passing plugin shell that supervises the crawl `Poller`. `roles/0` /
  `after_boot/0` / `config_surface/0` (discovery recipes, view registration)
  land in later stages; every other `Ezagent.Plugin` callback keeps its
  `use`-macro default (`[]` / `nil` / `:ok`).
  """

  use Application
  use Ezagent.Plugin

  # Compile-time env (works in stripped OTP releases where `Mix` is unavailable).
  @compile_env Mix.env()

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "dealscout",
      name: "dealscout",
      description: "dealscout discovery + matchmaking socialware",
      version: "0.1.0"
    }
  end

  # The crawl `Poller` GenServer. Skipped in `:test` (and any env where
  # `:skip_poller` is set) so the test suite never starts a real timer that
  # would hit the network — mirrors `Ezagent.Email.Inbound`'s test-boot skip.
  @impl Ezagent.Plugin
  def children do
    if Application.get_env(:ezagent_plugin_dealscout, :skip_poller, @compile_env == :test) do
      []
    else
      [EzagentPluginDealScout.Poller]
    end
  end

  # Discovery-leg recipes (role-as-data, RF-4): boot seeds each into
  # `Ezagent.Agent.RecipeRegistry` by `name`. Flavor-agnostic — flavor is chosen
  # per-agent on the Definition role-slot (a later Stage), never on the recipe.
  @impl Ezagent.Plugin
  def roles, do: EzagentPluginDealScout.Recipes.all()
end
