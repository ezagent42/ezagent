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
    `Ezagent.AgentFlavorRegistry`; PR-3 migrates the domain_chat agent
    resolver onto it, replacing the hardcoded `kind_module_from_flavor`
    map. The cc Agent Kind is the shared `Ezagent.Entity.Agent` (cc
    flavor lives in the `entity://agent/<ws>/cc_<name>` name prefix per
    SPEC v2 §5.14 — there is no cc-specific Kind module).
  - `config_surface/0` — `:flavor` surface. The `/plugins` config icon
    routes to this flavor's agent surface (SPEC §6.1).
  - `children/0` — an empty supervisor. cc's stateful surfaces are all
    either ETS-backed (`BridgeRegistry` — initialized in `after_boot/0`)
    or pulled in via the umbrella's lifecycle (`Socket` via
    `EzagentWeb.Endpoint`). The empty supervisor makes
    `Application.stop` work as the umbrella expects.
  - `after_boot/0` — Phase 3 hook: (a) initialize `BridgeRegistry`'s
    ETS table; (b) re-run `Ezagent.Workspace.Loader.load_all/0`. The
    `load_all/0` re-run is the Decision #112 boot-ordering fix —
    chat plugin's `Application.start` calls `load_all/0` BEFORE this
    plugin's Template Class is published, so workspaces declaring
    `cc.agent` templates were skipped; the post-publish re-run
    instantiates them. `boot/1`'s Phase 3 hook is exactly where this
    belongs — `template_classes/0` is published in Phase 2 first.

  PTY runtime (PtyServer + Supervisor + Registry) moved to the
  `ezagent_domain_pty` Tier-2 app in PR-A of the Domain.Pty SPEC
  (2026-05-21). cc plugin now spawns its claude PTY by building the
  full cmd string and calling `Ezagent.Domain.Pty.start/2`.

  `Ezagent.Behavior.Pty` Agent-Kind registration moved to
  `EzagentDomainChat.Application.start/2` in PR-B; `EzagentPluginCc`
  has no PTY-Behavior registration of its own — hence `behaviors/0`
  keeps the `use Ezagent.Plugin` default `[]`.
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

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
  def template_classes, do: [Ezagent.PluginCc.Template.CcAgent]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "cc",
        # cc agents are the shared Ezagent.Entity.Agent Kind — the cc
        # flavor lives only in the `entity://agent/<ws>/cc_<name>` name
        # prefix (SPEC v2 §5.14). There is no cc-specific Kind module.
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCc.Template.CcAgent
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "cc", label: "Claude Code Agents"}
  end

  @impl Ezagent.Plugin
  def children, do: []

  # Phase 3 post-register hook. `BridgeRegistry.init/0` is idempotent
  # (creates the ETS table if absent). The `load_all/0` re-run is the
  # Decision #112 boot-ordering fix — see moduledoc.
  #
  # PTY-orphan-restart 2026-05-26: reap stale `claude` OS processes
  # BEFORE running load_all. An orphan claude (from a brutal-killed
  # previous BEAM) would otherwise reconnect via the cc bridge channel
  # AND demand-spawn the Agent Kind, making `load_all`'s instantiate
  # short-circuit on "Kind already alive" and skip the PtyServer.
  # See `EzagentPluginCc.OrphanReaper` moduledoc.
  @impl Ezagent.Plugin
  def after_boot do
    :ok = BridgeRegistry.init()
    _ = maybe_reap_orphans()
    _ = Ezagent.Workspace.Loader.load_all()
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
end
