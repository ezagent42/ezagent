defmodule Ezagent.Plugin do
  @moduledoc """
  `Ezagent.Plugin` — the contract every ezagent plugin must implement.

  SPEC `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`.

  ## The philosophy — declare, don't call

  The codebase has a consistent **declarative** design: `@interface` →
  CLI + CmdK auto-derive; `form_fields/0` → Template forms; auto-derive
  → generic Kind admin. `Ezagent.Plugin` extends the SAME pattern to the
  plugin level. A plugin **declares** what it ships (Kinds, Behaviors,
  spawn fns, Template Classes, agent flavors, routing tables); the
  framework's `Ezagent.Plugin.boot/1` (§5) **does** the registration. The
  plugin author writes declarations, never touches a `*Registry` API —
  the plugin-isolation north star made structural.

  ## Implementing the contract

  A plugin module `use`s this behaviour:

      defmodule EzagentPluginEcho do
        use Ezagent.Plugin

        @impl true
        def plugin_info do
          %{slug: "echo", name: "Echo", description: "…", version: "0.1.0"}
        end

        # optional callbacks — defaults from `use Ezagent.Plugin` cover
        # the ones a plugin does not need.
      end

  Only `plugin_info/0` is mandatory. Every other callback has a
  `defoverridable` default supplied by `use Ezagent.Plugin` (§3.1) —
  `kinds/0 → []`, `config_surface/0 → nil`, `after_boot/0 → :ok`, etc.

  ## Two-layer enforcement (SPEC §3)

  1. **`use Ezagent.Plugin`** injects an `@after_compile` that does
     plugin-module-LOCAL validation only — `plugin_info/0` is
     implemented and well-formed. A failure raises `CompileError`. It
     does NOT dereference declared kind/behavior/template modules,
     which the umbrella may compile later (SPEC §3.1 / codex HIGH-3).
  2. The **`:ezagent_plugin_check` Mix compiler** (the non-bypassable
     app-level gate) does the cross-module checks after the whole
     `ezagent_plugin_*` app has compiled (SPEC §3.2).

  ## Boot

  `Ezagent.Plugin.boot/1` (§5) is the two-phase boot a plugin's OTP
  `Application.start/2` delegates to.
  """

  # SPEC §2 (codex HIGH-4): a `spawns/0` scheme is NOT a free string —
  # a plugin may only register a spawn fn under one of the SIX core
  # SPEC v3 schemes. It may NEVER introduce a new top-level scheme
  # (the `feishu://` deletion). `boot/1` + the app-level gate reject
  # anything else.
  @core_schemes ~w(entity session template resource workspace system)

  @typedoc """
  Plugin identity metadata — the data `plugins_live` renders a plugin
  card from. `slug` is a non-empty URL-safe unique string.
  """
  @type plugin_info :: %{
          slug: String.t(),
          name: String.t(),
          description: String.t(),
          version: String.t()
        }

  @typedoc """
  `{kind_module, action_atom, behavior_module}` — `boot/1` translates
  each into `Ezagent.BehaviorRegistry.register/3`.
  """
  @type behavior_decl :: {kind :: module(), action :: atom(), behavior :: module()}

  @typedoc """
  `{scheme, spawn_fun}` — `scheme` MUST be one of the six core schemes
  (`#{Enum.join(@core_schemes, " ")}`). `boot/1` rejects anything else
  (codex HIGH-4).
  """
  @type spawn_decl :: {scheme :: String.t(), spawn_fun :: (URI.t() -> {:ok, pid} | {:error, term})}

  @typedoc """
  `{table_name, opts}` — `boot/1` translates into
  `Ezagent.RoutingRegistry.declare_table/2`.
  """
  @type routing_decl :: {table_name :: atom(), opts :: keyword()}

  @typedoc """
  An agent-flavor → `{kind, template_class}` mapping. Declared by an
  agent-flavor plugin so the domain_chat spawn resolver consumes it
  from `Ezagent.AgentFlavorRegistry` declaratively instead of a
  hardcoded map (codex MEDIUM-5).
  """
  @type agent_flavor_decl :: %{
          flavor: String.t(),
          kind: module(),
          template_class: module()
        }

  @typedoc """
  What the `/plugins` config icon opens. V1 is `:route | :flavor | nil`
  — `:form` is rejected until the plugin-settings store ships (V2,
  codex MEDIUM-6).
  """
  @type config_surface ::
          %{kind: :route, path: String.t(), label: String.t()}
          | %{kind: :flavor, flavor: String.t(), label: String.t()}
          | nil

  # --- REQUIRED ---
  @callback plugin_info() :: plugin_info()

  # --- OPTIONAL (default [] / nil / :ok via `use Ezagent.Plugin`) ---
  @callback kinds() :: [module()]
  @callback behaviors() :: [behavior_decl()]
  @callback spawns() :: [spawn_decl()]
  @callback template_classes() :: [module()]
  @callback agent_flavors() :: [agent_flavor_decl()]
  @callback routing_tables() :: [routing_decl()]
  @callback config_surface() :: config_surface()
  @callback children() :: [Supervisor.child_spec() | {module(), term()}]
  @callback after_boot() :: :ok

  @optional_callbacks kinds: 0,
                      behaviors: 0,
                      spawns: 0,
                      template_classes: 0,
                      agent_flavors: 0,
                      routing_tables: 0,
                      config_surface: 0,
                      children: 0,
                      after_boot: 0

  @doc """
  The six core SPEC v3 URI schemes a plugin's `spawns/0` may register
  against. Used by `boot/1` and the `:ezagent_plugin_check` compiler.
  """
  @spec core_schemes() :: [String.t()]
  def core_schemes, do: @core_schemes

  @doc """
  `use Ezagent.Plugin` — see SPEC §3.1.

  Injects `@behaviour Ezagent.Plugin`, `defoverridable` defaults for
  every OPTIONAL callback, and an `@after_compile` pointing at
  `Ezagent.Plugin.Validator.__after_compile__/2` (plugin-module-LOCAL
  validation — raises `CompileError` on a missing / malformed
  `plugin_info/0`).
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Ezagent.Plugin

      # --- defaults for every OPTIONAL callback (SPEC §3.1) -----------
      # `defoverridable` lets a plugin replace any of these by simply
      # defining the callback itself.
      def kinds, do: []
      def behaviors, do: []
      def spawns, do: []
      def template_classes, do: []
      def agent_flavors, do: []
      def routing_tables, do: []
      def config_surface, do: nil
      def children, do: []
      def after_boot, do: :ok

      defoverridable kinds: 0,
                     behaviors: 0,
                     spawns: 0,
                     template_classes: 0,
                     agent_flavors: 0,
                     routing_tables: 0,
                     config_surface: 0,
                     children: 0,
                     after_boot: 0

      # Plugin-module-LOCAL validation only (codex HIGH-3): it must NOT
      # dereference declared kind/behavior/template modules — the
      # umbrella may compile them later. Cross-module checks live in
      # the `:ezagent_plugin_check` app-level gate (SPEC §3.2).
      @after_compile {Ezagent.Plugin.Validator, :__after_compile__}
    end
  end

  # ============================================================
  # boot/1 — two-phase declarative boot (SPEC §5)
  # ============================================================

  @doc """
  Two-phase declarative boot for a plugin module (SPEC §5).

  A plugin's OTP `Application.start/2` delegates to this:

      defmodule EzagentPluginCc.Application do
        use Application
        @impl true
        def start(_type, _args), do: Ezagent.Plugin.boot(EzagentPluginCc)
      end

  ## Phase 1 — start children

  `Supervisor.start_link/2` over `plugin_module.children/0` FIRST, named
  after the plugin. Any `DynamicSupervisor` / Registry / ETS the
  plugin's spawn fns or behaviors depend on is alive before anything is
  published (codex HIGH-2 — rev 1 published before the supervisor
  existed, so a spawn fn could be called against a missing supervisor).

  ## Phase 2 — publish

  Only now register: `BehaviorRegistry` per `behaviors/0`;
  `SpawnRegistry` per `spawns/0` (scheme allowlist checked — a scheme
  outside the six core schemes raises, codex HIGH-4);
  `TemplateRegistry` per `template_classes/0`; `AgentFlavorRegistry`
  per `agent_flavors/0`; `RoutingRegistry.declare_table/2` per
  `routing_tables/0`; `PluginRegistry` self-registration.

  ## Phase 3 — post-register hook

  `plugin_module.after_boot/0` for work that must run once the plugin
  is fully published (e.g. re-running `Workspace.Loader.load_all/0`).

  Returns the Phase-1 supervisor's `{:ok, pid}` so OTP `Application`
  semantics are preserved.
  """
  @spec boot(module()) :: {:ok, pid()} | {:error, term()}
  def boot(plugin_module) when is_atom(plugin_module) do
    # --- Phase 1: start children FIRST -----------------------------
    children = plugin_module.children()
    sup_name = Module.concat(plugin_module, "Supervisor")

    case Supervisor.start_link(children, strategy: :one_for_one, name: sup_name) do
      {:ok, sup_pid} ->
        # --- Phase 2: publish declarations ------------------------
        :ok = publish(plugin_module)

        # --- Phase 3: post-register hook --------------------------
        :ok = plugin_module.after_boot()

        # Return Phase-1 supervisor pid — OTP Application contract.
        {:ok, sup_pid}

      {:error, _} = err ->
        err
    end
  end

  # Phase 2 — translate every declaration into a registry call. The
  # plugin author never sees a `*Registry` module; `boot/1` owns the
  # mapping.
  defp publish(plugin_module) do
    Enum.each(plugin_module.behaviors(), fn {kind, action, behavior} ->
      :ok = Ezagent.BehaviorRegistry.register(kind, action, behavior)
    end)

    Enum.each(plugin_module.spawns(), fn {scheme, spawn_fun} ->
      assert_core_scheme!(plugin_module, scheme)
      :ok = Ezagent.SpawnRegistry.register(scheme, spawn_fun)
    end)

    Enum.each(plugin_module.template_classes(), fn class_module ->
      case Ezagent.TemplateRegistry.register(class_module) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError,
                "#{inspect(plugin_module)}: TemplateRegistry.register/1 rejected " <>
                  "#{inspect(class_module)} — #{inspect(reason)}"
      end
    end)

    Enum.each(plugin_module.agent_flavors(), fn decl ->
      :ok = Ezagent.AgentFlavorRegistry.register(decl)
    end)

    Enum.each(plugin_module.routing_tables(), fn {table_name, opts} ->
      :ok = Ezagent.RoutingRegistry.declare_table(table_name, opts)
    end)

    :ok = Ezagent.PluginRegistry.register(plugin_module)

    :ok
  end

  # codex HIGH-4 — a plugin may NOT introduce a top-level scheme. Only
  # the six core schemes are spawnable; reject anything else with a
  # clear error.
  defp assert_core_scheme!(plugin_module, scheme) do
    if scheme in @core_schemes do
      :ok
    else
      raise ArgumentError,
            "#{inspect(plugin_module)} declared a spawns/0 scheme #{inspect(scheme)} " <>
              "which is not one of the six core schemes " <>
              "(#{Enum.join(@core_schemes, ", ")}). Plugins do NOT own top-level " <>
              "URI schemes (SPEC §5.8 — the feishu:// deletion). Extend an " <>
              "existing scheme via its type segment, or register a Behavior on a " <>
              "core Kind instead."
    end
  end
end
