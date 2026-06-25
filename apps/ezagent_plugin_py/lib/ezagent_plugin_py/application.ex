defmodule EzagentPluginPy.Application do
  @moduledoc """
  PyAgent plugin OTP application — the `Ezagent.Plugin` contract module.

  ## What this plugin is

  `py` — a GENERAL script-driven Python agent flavor (py-agent spec rev3).
  Each py-agent runs an OPERATOR-SUPPLIED python script (installed at create
  into the agent's per-agent `config_dir`) in a per-agent
  `Ezagent.Domain.Python` subprocess. `py` is THE python flavor end-state;
  `echo` retires into it (P2) and `np` re-homes as a py-role (P4).

  ## Plugin authoring contract

  `start/2` collapses to `Ezagent.Plugin.boot(__MODULE__)`; the framework's
  two-phase `boot/1` reads the declaration callbacks below and performs every
  `*Registry` call (declare, don't call).

  ## What this plugin declares

  - `behaviors/0` — `{Ezagent.Entity.PyAgent, :receive | :reset | :configure}`
    → `Ezagent.Behavior.PyAgent`.
  - `template_classes/0` — the `py.agent` Template Class.
  - `agent_flavors/0` — flavor `"py"` → `{Ezagent.Entity.PyAgent,
    Ezagent.Template.PyAgent}`.
  - `config_surface/0` — `:flavor` surface.
  - `children/0` — `EzagentPluginPy.InstanceSupervisor`, the
    `DynamicSupervisor` parenting PyAgent Kind processes.

  ## Per-agent Python subprocess (NOT shared)

  The Template Class starts ONE `Ezagent.Domain.Python.Server` per PyAgent
  Kind keyed by the agent URI — same per-agent ownership as np/cc (scoped
  interpreter state + no cross-agent interleaving in the single-threaded
  python event loop).
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.Behavior.PyAgent, as: PyAgentBehavior
  alias Ezagent.Entity.PyAgent, as: PyAgentKind
  alias Ezagent.Template.PyAgent, as: PyAgentTemplate

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "py_agent",
      name: "Py Agent",
      description:
        "General script-driven Python agent — runs an operator-supplied " <>
          "python script per message via Ezagent.Domain.Python.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    for action <- PyAgentBehavior.actions() do
      {PyAgentKind, action, PyAgentBehavior}
    end
  end

  @impl Ezagent.Plugin
  def template_classes, do: [PyAgentTemplate]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "py",
        kind: PyAgentKind,
        template_class: PyAgentTemplate
      }
    ]
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "py", label: "Py Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginPy.InstanceSupervisor, strategy: :one_for_one}
    ]
  end
end
