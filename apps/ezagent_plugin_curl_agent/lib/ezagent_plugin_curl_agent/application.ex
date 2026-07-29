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

  - `behaviors/0` — `{Ezagent.Entity.Agent, :reset_conversation |
    :configure | :sync_result}` → `Ezagent.ActionSet.CurlAgent`
    (the action list comes from `Ezagent.ActionSet.CurlAgent.actions/0`).
    PR-6+7 (curl-as-flavor) folded curl into the unified `Entity.Agent`
    Kind and DELETED the standalone curl Kind + its legacy
    `:receive` / `:reset_conversation` / `:configure` shim bindings — the
    unified Agent Kind is the SOLE curl path (no back-compat window). The
    `curl_agent` snapshot migration that rewrote pre-fold rows onto
    `Entity.Agent` (`mix ezagent.curl.migrate`) has itself since been deleted
    (chore/retire-dead-kind-migrations) — the system never reached production,
    so no pre-fold `curl_agent` row ever needed migrating.
  - `template_classes/0` — the `curl.agent` Template Class, so
    workspaces can declare curl agents via the standard add-template UI.
  - `agent_flavors/0` — flavor `"curl"` → `{Ezagent.Entity.Agent,
    Ezagent.PluginCurlAgent.Template}`. Consumed by
    `Ezagent.AgentFlavorRegistry`; the domain_instance_message agent
    resolver consults it.
  - `config_surface/0` — `:flavor` surface. The `/plugins` config icon
    routes to this flavor's agent surface (SPEC §6.1).
  - `children/0` — `InstanceSupervisor`, a `DynamicSupervisor` retained
    for any per-instance child processes this plugin owns. Curl agents
    themselves now spawn under the unified Agent Kind's supervisor
    (`EzagentDomainInstanceMessage.AgentSupervisor`).
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

  alias Ezagent.ActionSet.CurlAgent, as: CurlAgentBehavior
  alias Ezagent.Entity.Agent, as: AgentKind
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
    # PR-6+7 (im/session/agent decomposition §3.5 / §OQ-1) — the curl STATE
    # Behavior is REPARENTED onto the unified `Ezagent.Entity.Agent` Kind
    # (curl flavor) and is the SOLE curl path. Curl agents spawn on
    # `Entity.Agent` with the curl per-instance behavior set, so the curl
    # actions (`reset_conversation` / `configure` / `sync_result`) bind there.
    # `:receive` is NOT a curl action — receive flows through `agent.receive`
    # → AgentBridge → the curl `:in_process_sync` adapter.
    #
    # The standalone curl Kind + its legacy `:receive` /
    # `:reset_conversation` / `:configure` shim bindings are DELETED (PR-7, no
    # rollback window — Allen). The `curl_agent` snapshot migration that
    # rewrote pre-fold rows onto `Entity.Agent` (`:curl_agent → :agent` cap
    # axis, `flavor: "curl"` slice, curl behaviors into `:kind_base`) has
    # itself since been deleted (chore/retire-dead-kind-migrations) — the
    # system never reached production, so there was no pre-fold row left to
    # migrate. `:api_keys` is already bound on `Entity.Agent` by
    # `EzagentDomainIdentity.Application` — no re-binding here.
    for action <- CurlAgentBehavior.actions(), do: {AgentKind, action, CurlAgentBehavior}
  end

  @impl Ezagent.Plugin
  def template_classes, do: [CurlAgentTemplate]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "curl",
        # PR-6+7 — the curl flavor resolves to the UNIFIED
        # `Ezagent.Entity.Agent` Kind (the standalone curl Kind is deleted).
        # Curl agents spawn on `Entity.Agent`; the curl-specific STATE
        # lives in the reparented `Behavior.CurlAgent`, selected for this
        # flavor via the per-instance behavior set (see `Template`).
        kind: AgentKind,
        template_class: CurlAgentTemplate,
        # PR-6 — register the `:in_process_sync` transport adapter (the HTTP
        # round-trip) UP at boot, symmetric to cc/codex's `bridge_adapter`.
        bridge_adapter: EzagentPluginCurlAgent.BridgeAdapter,
        # PR-6+7 (codex round-3 P1-1) — the per-instance behavior SET the
        # generic direct-create path (`Workspace.create_agent/3` →
        # `direct_spawn_flavor_agent/2`) threads as `:behaviors`. Curl's `kind`
        # is the SHARED `Entity.Agent`, whose nil-`:kind_base` default EXCLUDES
        # `Behavior.CurlAgent`; without this set a direct-created curl agent
        # captures the BASE (non-curl) behaviors → broken. Declaring it HERE (in
        # the plugin) keeps the workspace domain flavor-agnostic. Same set the
        # `curl.agent` Template threads, so the two create paths converge.
        instance_behaviors: &AgentKind.curl_behaviors/0
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
