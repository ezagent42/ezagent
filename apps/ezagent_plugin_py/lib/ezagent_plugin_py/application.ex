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

  - `behaviors/0` — `{Ezagent.Entity.Agent, :py_sync_result | :py_reset |
    :py_configure}` → `Ezagent.ActionSet.PyAgent` (P4b: py folded onto the
    UNIFIED `Entity.Agent` Kind; actions are py-namespaced to coexist with the
    other flavors' behaviors on the shared Kind).
  - `template_classes/0` — the `py.agent` Template Class.
  - `agent_flavors/0` — flavor `"py"` → `{Ezagent.Entity.Agent,
    Ezagent.Template.PyAgent}` with `instance_behaviors` (base Agent set +
    `Behavior.PyAgent`) and `bridge_adapter` (`EzagentPluginPy.BridgeAdapter`,
    the `:in_process_sync` transport that runs the script).
  - `config_surface/0` — `:flavor` surface.
  - `children/0` — `EzagentPluginPy.InstanceSupervisor`, a `DynamicSupervisor`
    retained for symmetry (py instances now spawn under the unified Agent Kind's
    supervisor; this stays empty, curl precedent).

  ## Per-agent Python subprocess (NOT shared)

  The Template Class starts ONE `Ezagent.Domain.Python.Server` per PyAgent
  Kind keyed by the agent URI — same per-agent ownership as np/cc (scoped
  interpreter state + no cross-agent interleaving in the single-threaded
  python event loop).

  ## Default agent seeding — `after_boot/0` → `seed_default/0` (P2)

  P2 retires the echo plugin. The deleted plugin seeded a live default agent
  (`entity://system/agent/<the legacy default name>`) in its own
  `after_boot/0`; several production endpoints depended on it (the OpenAI
  `/v1/chat/completions` default-agent path, the web home view). py re-seeds
  the equivalent default here as `entity://system/agent/py_default` — a
  py-agent running the shipped
  `priv/python/echo.py` operator script (echo-equivalence). The seed rides the
  CANONICAL `Ezagent.Kind.Template.provision_and_instantiate/4` seam (the
  post-authorization analog of the Loader path), which allocates the per-agent
  `config_dir`, writes `echo.py` into it, and starts the subprocess.

  Boot MUST survive a failed seed: `instantiate/3` shells out to `uv`, so any
  environment without `uv` on PATH would otherwise crash the entire app at
  boot. `seed_default/0` logs + returns `:ok` on failure (mirrors the deleted
  echo `after_boot/0`); the default agent self-heals on first
  `LocalRuntime.ensure_started/1` (re-spawns the subprocess from the installed
  script via `Behavior.PyAgent.activate/2`).
  """

  use Application
  use Ezagent.Plugin

  require Logger

  alias Ezagent.ActionSet.PyAgent, as: PyAgentBehavior
  alias Ezagent.ActionSet.Workspace.AgentCreate.PyTemplate
  alias Ezagent.Entity.Agent, as: AgentKind
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
      {AgentKind, action, PyAgentBehavior}
    end
  end

  @impl Ezagent.Plugin
  def template_classes, do: [PyAgentTemplate]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "py",
        kind: AgentKind,
        instance_behaviors: fn -> AgentKind.base_behaviors() ++ [PyAgentBehavior] end,
        bridge_adapter: EzagentPluginPy.BridgeAdapter,
        template_class: PyAgentTemplate,
        # RF-8 — py's fail-closed CapMint policy (py-agent P4). A py-ROLE (np)
        # requests `:py_agent` caps in its recipe; the role-create path reads
        # this policy from the flavor registry and mints exactly those caps.
        cap_policy: &EzagentPluginPy.CapPolicy.for_recipe/1
      }
    ]
  end

  # py-agent P4 — `np` is a py-ROLE: `py` flavor + the re-homed `np.py` script
  # (numpy/sympy whitelist intact) carried via the role-script channel
  # (`Recipe.script` → `Recipe.Compose.sandbox_content.script` → config_dir
  # `agent.py`). The plugin declares NO np Kind/Behavior — np runs the `py`
  # flavor on the UNIFIED `Entity.Agent` Kind + `Behavior.PyAgent`, distinguished
  # ONLY by its script (spec §0.1 "a role's safety travels with its SCRIPT").
  # `Ezagent.Plugin.boot/1`
  # registers this recipe via `RecipeRegistry.register/1` at boot (declare, don't
  # call). Created via `Workspace.create_agent(flavor: "py", role: "np")`.
  @impl Ezagent.Plugin
  def roles, do: [np_role_recipe()]

  @impl Ezagent.Plugin
  def resource_types do
    Ezagent.Resource.FsResolver.config_dir_resource_types([PyAgentTemplate])
  end

  @doc """
  The `np` py-role recipe — `py` flavor + the re-homed `np.py` script.

  Public so the role test asserts the exact recipe without re-deriving it. The
  script content is read from this plugin's priv dir (`priv/python/np.py`).

  ## No `requested_caps` — np needs no granted caps

  P4b folded py onto the unified `Entity.Agent` Kind, which carries the full
  Agent base set incl. `Behavior.Identity` — so a py-agent CAN now hold granted
  caps (the own-Kind `{:unknown_action, :grant_cap}` blocker is gone). np simply
  does not NEED any: the session→agent dispatch carries the sender's caps, and
  the reply effect presents its own inline `session.send` cap (#154). So the np
  role carries JUST the script (an empty recipe mints nothing, fail-closed). A
  future py-role that needs caps adds `:requested_caps` and py's `cap_policy`
  mints them — exactly the kanban-as-role pattern, now fully wired.
  """
  @spec np_role_recipe() :: map()
  def np_role_recipe do
    %{
      name: "np",
      script: np_script()
    }
  end

  # The re-homed np compute script (numpy/sympy whitelist intact) — read from
  # this plugin's priv dir at recipe-build time.
  defp np_script do
    :ezagent_plugin_py
    |> :code.priv_dir()
    |> Path.join("python/np.py")
    |> File.read!()
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

  @doc """
  Phase 3 post-register hook — seed the default py-agent (`py_default`).

  Runs AFTER Phase-2 `publish/1` registered this plugin's `agent_flavors/0` +
  `template_classes/0`, so `Ezagent.TemplateRegistry.lookup("py.agent")`
  (consumed by `PyTemplate.build/2`) resolves. This plugin deps
  `ezagent_domain_session` so the `entity://` dispatcher is published before
  this runs. Idempotent + boot-safe (see `seed_default/0`).
  """
  @impl Ezagent.Plugin
  def after_boot do
    # py-agent P4 — reap stale Domain.Python subprocesses orphaned by a
    # previous BEAM run BEFORE seeding (re-homed from the deleted np plugin).
    # py is THE python flavor, so the Domain.Python orphan reaper lives here.
    _ = maybe_reap_orphans()
    seed_default()
  end

  # Mix.env() resolved at compile time — works in stripped OTP releases.
  @compile_env Mix.env()
  @default_reap_enabled? @compile_env != :test

  defp maybe_reap_orphans do
    enabled? =
      Application.get_env(:ezagent_plugin_py, :reap_orphans_on_boot, @default_reap_enabled?)

    if enabled? do
      EzagentPluginPy.OrphanReaper.reap()
    else
      {:ok, 0}
    end
  end

  @doc """
  Seed `entity://system/agent/py_default` — a py-agent running the shipped
  `echo.py` operator script — via the canonical
  `Ezagent.Kind.Template.provision_and_instantiate/4` seam.

  Idempotent: `install_script/2` no-ops on byte-identical content and
  `Ezagent.Kind.spawn/2` adopts an already-started Kind. Boot-safe: a failed
  seed (e.g. `uv` absent) is logged + returns `:ok` — the default self-heals
  on first `LocalRuntime.ensure_started/1`. Extracted from `after_boot/0` so
  it is reusable (tests, ops) and the boot guard lives in one place.
  """
  @spec seed_default() :: :ok
  def seed_default do
    default_uri = default_uri()
    workspace_uri = Ezagent.URI.workspace(:system)
    :ok = Ezagent.AgentFlavorAttributes.put(default_uri, "py")

    tmpl = PyTemplate.build(default_uri, %{"script" => default_script()})
    tmpl_name = "py.agent." <> "py_default"

    # Already-seeded fast path (re-seed / supervisor restart): if the Kind is
    # alive, adopt it (self-heals the subprocess via activate/2) and skip the
    # provision — avoids a misleading "seed failed" log on the registration
    # race when the agent already exists.
    if Ezagent.LocalRuntime.kind_alive?(default_uri) do
      _ = Ezagent.LocalRuntime.ensure_started(default_uri)
      :ok
    else
      do_provision(tmpl_name, tmpl, workspace_uri)
    end
  end

  defp do_provision(tmpl_name, tmpl, workspace_uri) do
    case Ezagent.Kind.Template.provision_and_instantiate(
           PyAgentTemplate,
           tmpl_name,
           tmpl,
           workspace_uri
         ) do
      {:ok, _} ->
        :ok

      {:ok, _, _meta} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "EzagentPluginPy.seed_default/0: default py-agent (py_default) seed " <>
            "failed (#{inspect(reason)}); the OpenAI default-agent path + web " <>
            "home will self-heal on first ensure_started/1 (uv required)"
        )

        :ok
    end
  end

  @doc """
  URI of the default py-agent instance — seeded by `after_boot/0`. Replaces the
  deleted legacy default agent (P2). Consumed by the OpenAI default-agent path + the
  web home view.
  """
  @spec default_uri() :: Ezagent.URI.t()
  def default_uri, do: Ezagent.URI.agent(:system, :py_default)

  # The shipped `echo.py` operator script — the echo-equivalent default
  # behavior, read from this plugin's priv dir at seed time.
  defp default_script do
    :ezagent_plugin_py
    |> :code.priv_dir()
    |> Path.join("python/echo.py")
    |> File.read!()
  end
end
