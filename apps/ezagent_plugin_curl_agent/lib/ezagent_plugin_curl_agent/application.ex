defmodule EzagentPluginCurlAgent.Application do
  @moduledoc """
  CurlAgent plugin OTP application — the `Ezagent.Plugin` contract
  module.

  ## Plugin authoring contract (PR-2)

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  §3 / §8 Q3 — Allen confirmed: the OTP `Application` module IS the
  plugin contract module) this module `use`s **both** `Application`
  (OTP plumbing) and `Ezagent.Plugin` (the declarative contract).

  Registration is no longer imperative. `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework's two-phase
  `boot/1` reads the declaration callbacks below and performs every
  `*Registry` call — the plugin author never touches a registry API.
  The `:ezagent_plugin_check` Mix compiler (wired into `mix.exs`) is
  the non-bypassable gate that enforces this.

  ## What this plugin declares

  - `behaviors/0` — `{Ezagent.Entity.CurlAgent, :receive |
    :reset_conversation | :configure}` → `Ezagent.Behavior.CurlAgent`
    (the action list comes from `Ezagent.Behavior.CurlAgent.actions/0`).
  - `template_classes/0` — the `curl.agent` Template Class, so
    workspaces can declare CurlAgent instances via the standard
    add-template UI.
  - `agent_flavors/0` — flavor `"curl"` → `{Ezagent.Entity.CurlAgent,
    Ezagent.PluginCurlAgent.Template}`. Consumed by
    `Ezagent.AgentFlavorRegistry`; PR-3 migrates the domain_chat agent
    resolver onto it, replacing the hardcoded `kind_module_from_flavor`
    map.
  - `config_surface/0` — `:flavor` surface. The `/plugins` config icon
    routes to this flavor's agent surface (SPEC §6.1).
  - `children/0` — `InstanceSupervisor`, a `DynamicSupervisor` for the
    per-instance Kind processes the `curl.agent` Template Class spawns
    (`Ezagent.Entity.CurlAgent.supervisor/0` points here).
  - `after_boot/0` — re-runs `Ezagent.Workspace.Loader.load_all/0`.
    Decision #112 boot-ordering: when the chat plugin ran
    `load_all/0` before this plugin registered its Template Class,
    `curl.agent` templates were skipped; the post-publish re-run
    instantiates them. `boot/1`'s Phase 3 hook is exactly where this
    belongs — the Template Class is published in Phase 2 first.

  ## PR #149 (SPEC v2 §5.14)

  `Ezagent.AgentTypeRegistry` was deleted; this plugin does not
  register a `"curl"` flavor → spawn fn pair. Curl agents materialize
  via either `Ezagent.PluginCurlAgent.Template.instantiate/3`
  (workspace path) or the chat plugin's `entity://` SpawnRegistry fn
  resolving `entity://agent/<ws>/curl_<name>`.
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.Behavior.CurlAgent, as: CurlAgentBehavior
  alias Ezagent.Entity.CurlAgent, as: CurlAgentKind
  alias Ezagent.PluginCurlAgent.Template, as: CurlAgentTemplate

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "curl_agent",
      name: "Curl Agent",
      description: "HTTP-API agents (DeepSeek / OpenAI / etc.).",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    for action <- CurlAgentBehavior.actions() do
      {CurlAgentKind, action, CurlAgentBehavior}
    end
  end

  @impl Ezagent.Plugin
  def template_classes, do: [CurlAgentTemplate]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "curl",
        kind: CurlAgentKind,
        template_class: CurlAgentTemplate
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "curl", label: "Curl Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginCurlAgent.InstanceSupervisor, strategy: :one_for_one}
    ]
  end

  # Decision #112 boot-ordering: re-run the workspace loader once the
  # `curl.agent` Template Class is published (Phase 2), so workspaces
  # whose `load_all/0` ran before this plugin booted get instantiated.
  @impl Ezagent.Plugin
  def after_boot do
    _ = Ezagent.Workspace.Loader.load_all()
    :ok
  end
end
