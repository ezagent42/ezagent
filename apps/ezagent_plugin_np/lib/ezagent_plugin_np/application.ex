defmodule EzagentPluginNp.Application do
  @moduledoc """
  NpAgent plugin OTP application — the `Ezagent.Plugin` contract module.

  ## Plugin authoring contract

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`) this
  module `use`s **both** `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). Registration is
  declarative: `start/2` collapses to `Ezagent.Plugin.boot(__MODULE__)`;
  the framework's two-phase `boot/1` reads the declaration callbacks
  below and performs every `*Registry` call.

  ## What this plugin validates

  This is the Tier-3 plugin Allen asked for to validate
  `Ezagent.Domain.Python` (#256) end-to-end: a real Python subprocess
  loading numpy + sympy via uv (PEP-723 inline metadata) computes
  formulas the agent receives via chat.

  ## What this plugin declares

  - `behaviors/0` — `{Ezagent.Entity.NpAgent, :receive | :reset |
    :configure}` → `Ezagent.Behavior.NpAgent`.
  - `template_classes/0` — the `np.agent` Template Class.
  - `agent_flavors/0` — flavor `"np"` → `{Ezagent.Entity.NpAgent,
    Ezagent.PluginNp.Template.NpAgent}`. Consumed by
    `Ezagent.AgentFlavorRegistry`; the chat plugin's resolver maps the
    flavor to the Kind module so spawning `entity://agent/<ws>/np_<name>`
    just works.
  - `config_surface/0` — `:flavor` surface (the `/plugins` icon routes
    to this flavor's agent surface).
  - `children/0` — `EzagentPluginNp.InstanceSupervisor`, the
    `DynamicSupervisor` parenting NpAgent Kind processes
    (`Ezagent.Entity.NpAgent.supervisor/0` points here).

  ## Per-agent Python subprocess (NOT shared)

  The Template Class starts ONE `Ezagent.Domain.Python.Server` per
  NpAgent Kind, identified by the agent URI as the Domain.Python
  handle. The choice mirrors per-cc-agent `Domain.Pty` ownership:
  - keeps Python interpreter state (numpy globals, sympy caches)
    scoped to the agent;
  - prevents cross-agent message interleaving inside the
    single-threaded Python event loop (`ezagent_python.run/0` is
    single-threaded by design — see Domain.Python SPEC §6.2).

  ## Expression safety

  See `priv/python/np_compute_server.py` moduledoc. The Python script
  uses `sympy.sympify` for symbolic parsing + a numpy whitelist
  evaluator for numeric expressions — NEVER raw `eval()`. A malicious
  sender cannot execute arbitrary Python; the Python handler's
  validation is the structural defense.
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.Behavior.NpAgent, as: NpAgentBehavior
  alias Ezagent.Entity.NpAgent, as: NpAgentKind
  alias Ezagent.PluginNp.Template.NpAgent, as: NpAgentTemplate

  # PTY-phase-state-machine 2026-05-26 follow-up (b) codex HIGH-1
  # fix: register `Ezagent.Behavior.Lifecycle` `:terminate` on the
  # NpAgent Kind so the LV `restart_pty` dispatch (and any other
  # caller using `?action=lifecycle.terminate`) routes through
  # CapBAC + audit + supervisor restart. Matches the cc plugin's
  # symmetric registration in `EzagentDomainChat.Application` for
  # the cc Agent Kind.
  alias Ezagent.Behavior.Lifecycle, as: LifecycleBehavior

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "np_agent",
      name: "Np Agent",
      description:
        "Python-backed compute agent (numpy + sympy) — validates " <>
          "Ezagent.Domain.Python.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    np_actions =
      for action <- NpAgentBehavior.actions() do
        {NpAgentKind, action, NpAgentBehavior}
      end

    # PTY-phase-state-machine 2026-05-26 follow-up (b) codex HIGH-1
    # fix — register Lifecycle's :terminate on NpAgent Kind so the
    # LV "Dead — Restart" badge button (`restart_pty` event) can
    # dispatch `?action=lifecycle.terminate` against np-flavor agents.
    lifecycle_actions =
      for action <- LifecycleBehavior.actions() do
        {NpAgentKind, action, LifecycleBehavior}
      end

    np_actions ++ lifecycle_actions
  end

  @impl Ezagent.Plugin
  def template_classes, do: [NpAgentTemplate]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "np",
        kind: NpAgentKind,
        template_class: NpAgentTemplate
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "np", label: "Np Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginNp.InstanceSupervisor, strategy: :one_for_one}
    ]
  end

  # PTY-orphan-restart 2026-05-26 — reap stale Python OS processes left
  # behind by a previous BEAM instance (brutal kill / SIGKILL skipped
  # erlexec's cleanup). Runs BEFORE the chat plugin's load_all/0 fires
  # the np Template Class — so an orphan Python subprocess can't claim
  # the agent URI's :via Registry name and lock out the fresh spawn.
  #
  # Skip in `:test` env by default — see EzagentPluginCc.Application for
  # the same rationale (tests start a fresh BEAM with empty Python
  # registry, so every orphan looks reapable).
  @impl Ezagent.Plugin
  def after_boot do
    _ = maybe_reap_orphans()
    :ok
  end

  # Mix.env() resolved at compile time — works in stripped OTP releases.
  @compile_env Mix.env()
  @default_reap_enabled? @compile_env != :test

  defp maybe_reap_orphans do
    enabled? =
      Application.get_env(:ezagent_plugin_np, :reap_orphans_on_boot, @default_reap_enabled?)

    if enabled? do
      EzagentPluginNp.OrphanReaper.reap()
    else
      {:ok, 0}
    end
  end
end
