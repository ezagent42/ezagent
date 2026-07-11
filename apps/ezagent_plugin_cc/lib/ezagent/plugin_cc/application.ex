defmodule EzagentPluginCc.Application do
  @moduledoc """
  CC plugin OTP application — the `Ezagent.Plugin` contract module.

  The unified Claude Code agent plugin (Allen 2026-05-19: merged from
  the previous `ezagent_plugin_cc_pty` + `ezagent_plugin_cc_channel`
  apps; both predecessors deleted).

  ## Plugin authoring contract (PR-3)

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  §3 / §8 Q3 — Allen confirmed: the OTP `Application` module IS the
  plugin contract module) this module `use`s **both** `Application`
  (OTP plumbing) and `Ezagent.Plugin` (the declarative contract).

  Registration is no longer imperative. `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework's two-phase
  `boot/1` reads the declaration callbacks below and performs every
  `*Registry` call — the plugin author never touches a registry API
  (the plugin-isolation north star, made structural). The
  `:ezagent_plugin_check` Mix compiler (wired into `mix.exs`) is the
  non-bypassable gate that enforces this.

  ## What this plugin declares

  - `template_classes/0` — the unified `cc.agent` Template Class
    (PR-D2, Allen 2026-05-19 — replaces the pre-existing cc.pty +
    cc.channel_instance split). Operators add ONE template per CC
    agent via the standard add-template chain.
  - `agent_flavors/0` — flavor `"cc"` → `{Ezagent.Entity.Agent,
    Ezagent.PluginCc.Template.CcAgent}`. Consumed by
    `Ezagent.AgentFlavorRegistry`; PR-3 migrates the domain_instance_message agent
    resolver onto it, replacing the hardcoded `kind_module_from_flavor`
    map. The cc Agent Kind is the shared `Ezagent.Entity.Agent` (cc
    flavor lives in the `entity://agent/<ws>/cc_<name>` name prefix per
    SPEC v2 §5.14 — there is no cc-specific Kind module).
  - `config_surface/0` — `:flavor` surface. The `/plugins` config icon
    routes to this flavor's agent surface (SPEC §6.1).
  - `children/0` — an empty supervisor. cc's bridge state lives in the
    AgentBridge domain app, and socket mounting is pulled in via the
    umbrella's lifecycle (`EzagentWeb.Endpoint`). The empty supervisor
    makes `Application.stop` work as the umbrella expects.
  - `after_boot/0` — Phase 3 hook: re-run
    `Ezagent.Workspace.Loader.load_all/0`. The `load_all/0` re-run is
    the Decision #112 boot-ordering fix —
    chat plugin's `Application.start` calls `load_all/0` BEFORE this
    plugin's Template Class is published, so workspaces declaring
    `cc.agent` templates were skipped; the post-publish re-run
    instantiates them. `boot/1`'s Phase 3 hook is exactly where this
    belongs — `template_classes/0` is published in Phase 2 first.

  PTY runtime (PtyServer + Supervisor + Registry) moved to the
  `ezagent_domain_pty` Tier-2 app in PR-A of the Domain.Pty SPEC
  (2026-05-21). cc plugin now spawns its claude PTY by building the
  full cmd string and calling `Ezagent.Domain.Pty.start/2`.

  `Ezagent.ActionSet.Pty` Agent-Kind registration moved to
  `EzagentDomainInstanceMessage.Application.start/2` in PR-B; `EzagentPluginCc`
  has no PTY-Behavior registration of its own — hence `behaviors/0`
  keeps the `use Ezagent.Plugin` default `[]`.
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.ActionSet.CcHeadlessAgent, as: CcHeadlessBehavior

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "cc",
      name: "Claude Code",
      description: "Spawn Claude Code agents via PTY.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    for action <- CcHeadlessBehavior.actions(),
        do: {Ezagent.Entity.Agent, action, CcHeadlessBehavior}
  end

  @impl Ezagent.Plugin
  def template_classes,
    do: [
      Ezagent.PluginCc.Template.CcAgent,
      Ezagent.PluginCc.Template.CcHeadlessAgent,
      # DeepSeek provider variants (backend dimension, orthogonal to transport).
      Ezagent.PluginCc.Template.CcDeepseekAgent,
      Ezagent.PluginCc.Template.CcHeadlessDeepseekAgent
    ]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "cc",
        # cc agents are the shared Ezagent.Entity.Agent Kind — the cc
        # flavor lives only in the `entity://agent/<ws>/cc_<name>` name
        # prefix (SPEC v2 §5.14). There is no cc-specific Kind module.
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCc.Template.CcAgent,
        bridge_adapter: EzagentPluginCc.BridgeAdapter
      },
      %{
        flavor: "cc-headless",
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCc.Template.CcHeadlessAgent,
        bridge_adapter: EzagentPluginCc.CcHeadlessBridgeAdapter,
        instance_behaviors: &Ezagent.Entity.Agent.cc_headless_behaviors/0
      },
      # --- DeepSeek provider variants (backend dimension) --------------------
      # Same transport/bridge/behaviors as cc / cc-headless; the ONLY difference
      # is the LLM backend (DeepSeek's Anthropic-compatible endpoint via the
      # DeepSeek env block, API-key auth from DEEPSEEK_API_KEY — no OAuth login).
      # Distinct flavors because AgentFlavorRegistry enforces 1:1
      # flavor↔template_class; all DeepSeek behaviour lives in
      # `Ezagent.PluginCc.Provider`.
      %{
        flavor: "cc-deepseek",
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCc.Template.CcDeepseekAgent,
        bridge_adapter: EzagentPluginCc.DeepseekBridgeAdapter
      },
      %{
        flavor: "cc-headless-deepseek",
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCc.Template.CcHeadlessDeepseekAgent,
        bridge_adapter: EzagentPluginCc.CcHeadlessDeepseekBridgeAdapter,
        instance_behaviors: &Ezagent.Entity.Agent.cc_headless_behaviors/0
      }
    ]
  end

  # Built-in role recipes (role-foundation RF-4/RF-9). `Ezagent.Plugin.boot/1`
  # Phase 2 registers each one in `Ezagent.Agent.RecipeRegistry` by name. The
  # orchestrator is the load-bearing existing role and the `roles/0` exemplar —
  # registering it here makes it a first-class named role
  # (`RecipeRegistry.lookup("orchestrator")`) consumed by the cc-flavor loader
  # (`OrchestratorBootstrap.resolve_orchestrator_recipe/0`) at agent-spawn time,
  # AND the re-point target for the future persisted
  # `template://system/recipe/orchestrator` Template subtype.
  @impl Ezagent.Plugin
  def roles, do: [Ezagent.Orchestrator.OrchestratorRecipe.recipe()]

  @impl Ezagent.Plugin
  def resource_types do
    Ezagent.Resource.FsResolver.config_dir_resource_types([
      Ezagent.PluginCc.Template.CcAgent,
      Ezagent.PluginCc.Template.CcHeadlessAgent
    ])
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "cc", label: "Claude Code Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {Registry, keys: :unique, name: EzagentPluginCc.SdkSidecarRegistry},
      {DynamicSupervisor, name: EzagentPluginCc.SdkSidecarSupervisor, strategy: :one_for_one}
    ]
  end

  # Phase 3 post-register hook. The `load_all/0` re-run is the Decision
  # #112 boot-ordering fix — see moduledoc.
  #
  # PTY-orphan-restart 2026-05-26: reap stale `claude` OS processes
  # BEFORE running load_all. An orphan claude (from a brutal-killed
  # previous BEAM) would otherwise reconnect via the cc bridge channel
  # AND demand-spawn the Agent Kind, making `load_all`'s instantiate
  # short-circuit on "Kind already alive" and skip the PtyServer.
  # See `EzagentPluginCc.OrphanReaper` moduledoc.
  @impl Ezagent.Plugin
  def after_boot do
    # PR-8 (transport #53) — the orchestrator-MCP transport subsystem moved
    # from `ezagent_domain_session` INTO this plugin. Their lazy-`init/0`
    # ETS tables + the context-port implementation registration move here with
    # them.
    #
    # `McpRegistry` — the `orchestrator_uri → bound McpServer context` table.
    # Agent live-join readiness is now the generic domain-agent contract
    # (`Ezagent.Agent.LiveJoinRegistry`) keyed by `agent_uri`.
    :ok = Ezagent.Orchestrator.McpRegistry.init()
    :ok = Ezagent.Agent.LiveJoinRegistry.init()

    :ok =
      Ezagent.Session.OrchestratorContextPort.put_impl(
        EzagentPluginCc.Orchestrator.ContextAdapter
      )

    _ = maybe_reap_orphans()
    _ = maybe_reap_cc_sdk_orphans()
    _ = Ezagent.Workspace.Loader.load_all()

    # PR-8 (transport #53) APPROVED SEED RELOCATION — the cc-orchestrator
    # AgentTemplate seed (`template://agent/system/cc-orchestrator`) moved out of
    # `EzagentDomainInstanceMessage.Application.start/2` into here. The seed depends on the
    # `Ezagent.Orchestrator.CcOrchestratorSeed` module (now cc-resident) and on
    # the cc flavor + templates being published, so it belongs after `load_all/0`
    # in cc's `after_boot`. Same semantics as the old im call: `seed/0` is
    # idempotent + best-effort (logs + `:ok` on soft failure; raises `InstallError`
    # only on a bridge/schema install failure, deliberately uncaught).
    :ok = Ezagent.Orchestrator.CcOrchestratorSeed.seed()

    # 2026-05-31 orchestrator-startup-atomicity §4 — the test-only
    # `session://default/system/main` seed runs HERE (not in
    # `EzagentDomainInstanceMessage.Application.start/2`) because the atomic
    # `create_session/3` rolls `main` back when the orchestrator can't be
    # ensured. The orchestrator needs the `"cc"` agent flavor this plugin
    # registers; chat boots before us, so seeding at chat-boot always hit
    # `{:unknown_flavor, "cc"}` and tore `main` down. By `after_boot`,
    # `agent_flavors/0` has published `"cc"`, so the orchestrator spawns
    # and `main` persists. Same boot-order fix the echo seed uses.
    _ = EzagentDomainInstanceMessage.Application.maybe_seed_main_session_for_tests()
    :ok
  end

  # PTY-orphan-restart 2026-05-26 — orphan reaping is a real-world
  # operational concern (brutal-killed BEAM leaves OS claudes alive).
  # In `:test` env we SKIP the reap by default: test runs may legitimately
  # have orphan claudes from prior e2e runs that the next test
  # consciously wants to inspect / reuse, and the reaper would kill
  # them indiscriminately (every test starts a fresh BEAM with empty
  # `Ezagent.Domain.Pty` registry, so EVERY orphan looks reapable).
  # Operators can flip the config in test-env CI / dedicated e2e
  # tests via `config :ezagent_plugin_cc, reap_orphans_on_boot: true`.
  #
  # `Mix.env()` resolution at compile time (the module attribute
  # bakes in the env at compile, not at runtime) — same pattern as
  # `Ezagent.PluginFeishu.Application` so this works in stripped
  # releases too.
  @compile_env Mix.env()
  @default_reap_enabled? @compile_env != :test

  defp maybe_reap_orphans do
    enabled? =
      Application.get_env(:ezagent_plugin_cc, :reap_orphans_on_boot, @default_reap_enabled?)

    if enabled? do
      EzagentPluginCc.OrphanReaper.reap()
    else
      {:ok, 0}
    end
  end

  # cc-sdk sidecar orphan reaper (erlexec sidecar runtime, 2026-06-25).
  # Same test-skip gate as maybe_reap_orphans/0: disabled in :test by
  # default, flippable via config :ezagent_plugin_cc, :reap_orphans_on_boot.
  # Ezagent.Runtime.OrphanReaper.reap/1 returns :ok (not {:ok, n}).
  defp maybe_reap_cc_sdk_orphans do
    enabled? =
      Application.get_env(:ezagent_plugin_cc, :reap_orphans_on_boot, @default_reap_enabled?)

    if enabled? do
      Ezagent.Runtime.OrphanReaper.reap("cc-sdk")
    else
      :ok
    end
  end
end
