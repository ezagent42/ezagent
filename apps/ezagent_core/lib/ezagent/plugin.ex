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

      defmodule EzagentPluginPy do
        use Ezagent.Plugin

        @impl true
        def plugin_info do
          %{slug: "py", name: "Py", description: "…", version: "0.1.0"}
        end

        # optional callbacks — defaults from `use Ezagent.Plugin` cover
        # the ones a plugin does not need.
      end

  Only `plugin_info/0` is mandatory. Every other callback has a
  `defoverridable` default supplied by `use Ezagent.Plugin` (§3.1) —
  `kinds/0 → []`, `config_surface/0 → nil`, `after_boot/0 → :ok`, etc.

  ## `spawns/0` is RESERVED (codex PR-5 HIGH-1)

  `spawns/0` once let a plugin register a `SpawnRegistry` spawn fn for
  a URI scheme. That is a hole: `SpawnRegistry` is scheme-keyed and a
  `register/2` OVERWRITES — so a plugin declaring `{"entity", fun}`
  takes ownership of ALL `entity://` spawning. A plugin must NEVER own
  a scheme-level dispatcher (invariant 8). All six core schemes
  (`entity, session, template, resource, workspace, system`) are
  owned by core/domain — there is no valid plugin spawn declaration.
  `spawns/0` must return `[]`; `boot/1` and the `:ezagent_plugin_check`
  gate REJECT any non-empty value. To contribute spawnable Kinds, a
  plugin extends an existing scheme via its Kind's type/name prefix
  (e.g. `entity://agent/<ws>/cc_<name>` — the cc plugin's flavor lives
  in the name prefix) or registers a Behavior on a core Kind.

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

  # SPEC §2 + PR-5 codex HIGH-1: the six core SPEC v3 URI schemes.
  # ALL six are owned by core/domain — a plugin owns NONE of them.
  #
  # `spawns/0` originally let a plugin register a spawn fn for a core
  # scheme; codex PR-5 HIGH-1 showed that is itself the bug: a
  # scheme-keyed `SpawnRegistry.register/2` OVERWRITES, so a plugin
  # declaring `{"entity", fun}` passes the allowlist yet takes
  # ownership of ALL `entity://` spawning. A plugin must NEVER own a
  # scheme-level dispatcher (invariant 8). Since every scheme is
  # core-owned, there is no valid plugin spawn declaration at all —
  # `boot/1` and the `:ezagent_plugin_check` gate now REJECT any
  # non-empty `spawns/0`. The callback is retained (so a plugin
  # declaring one fails loudly with a precise message rather than a
  # silent no-op), but it is effectively reserved/unusable.
  #
  # A plugin extends an existing scheme via its Kind's type/name
  # prefix (e.g. `entity://agent/<ws>/cc_<name>`) or registers a
  # Behavior on a core Kind — it never registers a scheme spawn fn.
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
  `{scheme, spawn_fun}` — **RESERVED / REJECTED** (codex PR-5 HIGH-1).

  Every URI scheme is owned by core/domain; a plugin may not register
  a scheme-level spawn fn (doing so would let it hijack a core
  scheme's dispatcher — invariant 8). `boot/1` and the
  `:ezagent_plugin_check` gate reject any non-empty `spawns/0`. The
  type is kept only so a misuse fails with a precise diagnostic.
  Extend a scheme via a Kind type/name prefix instead.
  """
  @type spawn_decl ::
          {scheme :: String.t(), spawn_fun :: (URI.t() -> {:ok, pid} | {:error, term})}

  @typedoc """
  `{table_name, opts}` — `boot/1` translates into
  `Ezagent.RoutingRegistry.declare_table/2`.
  """
  @type routing_decl :: {table_name :: atom(), opts :: keyword()}

  @typedoc """
  An agent-flavor → `{kind, template_class}` mapping. Declared by an
  agent-flavor plugin so the domain_instance_message spawn resolver consumes it
  from the domain-agent flavor registry declaratively instead of a
  hardcoded map (codex MEDIUM-5).
  """
  @type agent_flavor_decl :: %{
          optional(:bridge_adapter) => module() | nil,
          # PR-6+7 (curl-as-flavor) — an OPTIONAL 0-arity thunk returning the
          # per-instance behavior SET to thread as `:behaviors` at a direct
          # `Kind.spawn`. A flavor whose `kind` is a SHARED Kind (`Entity.Agent`)
          # but whose runtime behavior is a flavor-specific SUBSET (curl) declares
          # it here, so the generic direct-spawn path materializes the flavor's
          # behaviors WITHOUT the workspace domain knowing about curl. Absent
          # (np / dedicated-Kind flavor) → nil → spawn omits `:behaviors`.
          optional(:instance_behaviors) => (-> [module()]) | nil,
          # RF-8 — OPTIONAL fail-closed CapMint cap-policy FACTORY. Absent → nil.
          optional(:cap_policy) => ([map()] -> (map() -> boolean())) | nil,
          flavor: String.t(),
          kind: module(),
          template_class: module()
        }

  @typedoc """
  An ExternalMirror adapter declaration (SPEC
  `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §5.1).

  The declaration shape is keyed off the adapter's KIND
  (`Ezagent.ExternalMirror.Adapter.kind_of/1`, P3-1):

  - **`:push`** (the default) — a `{adapter_module, binding_module}`
    PAIR. Grill-5 enforces bidirectional 1:1: `adapter.binding_module()
    == binding` AND `binding.adapter_module() == adapter` AND `adapter
    != binding`. Both registries (`AdapterRegistry` + `BindingRegistry`)
    are written. UNCHANGED from PR-EM-1.

  - **`:pull`** (P3-1) — a BARE adapter module (a single `module()`,
    NOT a tuple). A pull adapter has NO per-binding transport, so it
    declares no binding and only `AdapterRegistry` is written (no
    `BindingRegistry` row — the no-binding invariant). The socialware
    customer feed (P3-2) is the first real pull adapter.

  Verified at compile time by the `:ezagent_plugin_check` Mix compiler;
  re-verified defensively at boot by `Ezagent.Plugin.boot/1`.
  """
  @type adapter_decl ::
          {adapter_module :: module(), binding_module :: module()}
          | (pull_adapter_module :: module())

  @typedoc """
  A plugin-contributed `resource://<ws>/<type>/<name>` type declaration
  (plugin-resource SPEC §4.1). `{type, spec}` where `spec` is the EXISTING
  resolver `type_spec` (`%{backend_component, authority}`) — plugins reuse the
  resolver's own shape, no new type. `boot/1` Phase 2 passes the whole list to
  `Ezagent.Resource.FsResolver.Registry.register_all/1` (write-once on both
  `<type>` and `backend_component`, all-or-nothing). Both `<type>` and
  `backend_component` SHOULD be plugin-slug-prefixed (`world-layouts`, not bare
  `layouts`) so two plugins never collide and brick startup (D7).
  """
  @type resource_type_decl ::
          {type :: String.t(), Ezagent.Resource.FsResolver.type_spec()}

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

  @doc """
  RESERVED — must return `[]`. A plugin may not register a
  scheme-level spawn fn; `boot/1` and the `:ezagent_plugin_check`
  gate reject any non-empty list (codex PR-5 HIGH-1).
  """
  @callback spawns() :: []
  @callback template_classes() :: [module()]
  @callback agent_flavors() :: [agent_flavor_decl()]

  # Built-in role recipes (role-foundation RF-4) — recipe MAPs registered in
  # `Ezagent.RoleRegistry` by name at boot. See that module + `Ezagent.Role`.
  @callback roles() :: [map()]

  @doc """
  ExternalMirror adapter declarations (SPEC
  `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §5.1).

  Each entry is either (P3-1):

  - a `{adapter_module, binding_module}` PAIR for a `:push` adapter —
    `Ezagent.Plugin.boot/1` verifies Grill-5 (both implement their
    behaviour, bidirectional `binding_module/0` / `adapter_module/0`
    match, distinct modules) then registers via
    `AdapterRegistry.register/1` + `BindingRegistry.register_module/2`;
    OR
  - a BARE `adapter_module` for a `:pull` adapter — registered via
    `AdapterRegistry.register/1` ONLY (no binding; pull adapters have
    no per-binding transport).

  Default `[]` via `use Ezagent.Plugin`.
  """
  @callback adapters() :: [adapter_decl()]
  @callback routing_tables() :: [routing_decl()]

  @doc """
  Plugin-contributed `resource://<ws>/<type>/<name>` type declarations
  (plugin-resource SPEC §4.1). `boot/1` Phase 2 passes the list to
  `Ezagent.Resource.FsResolver.Registry.register_all/1`. Default `[]` via
  `use Ezagent.Plugin`.
  """
  @callback resource_types() :: [resource_type_decl()]
  @callback config_surface() :: config_surface()
  @callback children() :: [Supervisor.child_spec() | {module(), term()}]
  @callback after_boot() :: :ok

  @optional_callbacks kinds: 0,
                      behaviors: 0,
                      spawns: 0,
                      template_classes: 0,
                      agent_flavors: 0,
                      roles: 0,
                      adapters: 0,
                      routing_tables: 0,
                      resource_types: 0,
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
      def roles, do: []
      def adapters, do: []
      def routing_tables, do: []
      def resource_types, do: []
      def config_surface, do: nil
      def children, do: []
      def after_boot, do: :ok

      defoverridable kinds: 0,
                     behaviors: 0,
                     spawns: 0,
                     template_classes: 0,
                     agent_flavors: 0,
                     roles: 0,
                     adapters: 0,
                     routing_tables: 0,
                     resource_types: 0,
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
  # publish_after_all_registered/2 — cross-registry hook primitive
  # (SPEC docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md §5)
  # ============================================================

  @doc """
  Register `hook_fn` to fire ONCE when every `(registry_module, key)`
  in `registries` has a lookup hit.

  This is the cross-registry "wait until both/all are populated"
  primitive lifted from `Ezagent.ExternalMirror.AdapterInstall`'s
  symmetric `maybe_install*/1` pair per the audit SPEC.

  ## Contract

  - `registries` is a non-empty list of `{registry_module, key}` pairs.
    Each `registry_module` MUST implement `lookup/1` returning
    `{:ok, value} | :error` AND MUST call
    `Ezagent.Plugin.RegistrationHooks.notify_subscribers(__MODULE__, key)`
    from its successful-insert path.
  - `hook_fn` is a zero-arity function fired ONCE when ALL registries
    resolve. If they all resolve at call time, fires synchronously
    before this function returns. Otherwise the hook is queued.
  - Idempotent: if a hook's registries-list is fully resolved by a
    later `notify_subscribers/2` call, the hook fires exactly once
    and is deleted from the pending table.
  - Hot uninstall is V2 — removing a registry entry does NOT
    trigger any "uninstall" hook.

  ## Example — ExternalMirror's AdapterInstall (first consumer)

      Ezagent.Plugin.publish_after_all_registered(
        [
          {Ezagent.ExternalMirror.AdapterRegistry, adapter_id},
          {Ezagent.ExternalMirror.BindingRegistry, adapter_id}
        ],
        fn -> Ezagent.ExternalMirror.AdapterInstall.install(adapter_module) end
      )

  Whichever of AdapterRegistry / BindingRegistry calls
  `notify_subscribers/2` SECOND will trigger `install/1`. The plugin's
  `Plugin.publish_adapters!` registration order is irrelevant; both
  registries are populated by the time install runs, so
  `BindingRegistry.lookup!/1` in the worker dispatch path resolves.
  """
  @spec publish_after_all_registered(
          [{module(), term()}],
          (-> :ok)
        ) :: :ok
  def publish_after_all_registered(registries, hook_fn)
      when is_list(registries) and registries != [] and is_function(hook_fn, 0) do
    Ezagent.Plugin.RegistrationHooks.publish_after_all_registered(registries, hook_fn)
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
  `TemplateRegistry` per `template_classes/0`; the domain-agent flavor publish
  hook per `agent_flavors/0`; `RoutingRegistry.declare_table/2` per
  `routing_tables/0`; `Resource.FsResolver.Registry.register_all/1`
  per `resource_types/0` (write-once on both `<type>` and
  `backend_component`, all-or-nothing; raises `ArgumentError` naming
  the plugin on a duplicate/invalid decl); `PluginRegistry`
  self-registration.

  A non-empty `spawns/0` is REJECTED with an `ArgumentError` — every
  URI scheme is core/domain-owned, so a plugin scheme spawn would
  hijack a core dispatcher (codex PR-5 HIGH-1).

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
    # codex PR-5 HIGH-1 — a plugin must not own a scheme-level spawn.
    # Reject BEFORE any other publish so a misconfigured plugin fails
    # loudly at boot rather than silently hijacking a core scheme.
    reject_spawns!(plugin_module)

    Enum.each(plugin_module.behaviors(), fn {kind, action, behavior} ->
      :ok = Ezagent.CapabilityRegistry.register(kind, action, behavior)
    end)

    Enum.each(plugin_module.agent_flavors(), fn decl ->
      assert_agent_flavor!(plugin_module, decl)
    end)

    Enum.each(plugin_module.config_surface() |> List.wrap(), fn surface ->
      assert_config_surface!(plugin_module, surface)
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
      :ok = Ezagent.Plugin.FlavorPublishHook.publish_agent_flavor(decl)
      :ok = maybe_register_bridge_adapter(decl)
    end)

    # role-foundation RF-4 — `RoleRegistry`/`Role` are core so `boot/1` calls
    # `register/1` DIRECTLY (it validates via `Role.new/1`) — no publish hook.
    Enum.each(plugin_module.roles(), fn recipe ->
      :ok = Ezagent.RoleRegistry.register(recipe)
    end)

    Enum.each(plugin_module.routing_tables(), fn {table_name, opts} ->
      :ok = Ezagent.RoutingRegistry.declare_table(table_name, opts)
    end)

    # ExternalMirror PR-EM-1 (SPEC §5.1) — codex r1 HIGH-1 fix:
    # publish ALL adapter pairs atomically. Prevalidate every entry
    # (Grill-5 + duplicate-id detection inside this batch) BEFORE
    # any registry write; then write all pairs, rolling back the
    # already-written rows on any registration failure.
    #
    # The previous shape iterated and wrote per-pair — a later
    # validation failure left earlier pairs registered with no
    # rollback, so `list_adapters/0` could advertise an adapter
    # whose plugin boot never completed.
    #
    # Step 7 (CapabilityRegistry per `adapter.cap_subject()`) is
    # DEFERRED to PR-EM-2 when `Behavior.ExternalMirror` lands.
    publish_adapters!(plugin_module, plugin_module.adapters())

    :ok = Ezagent.PluginRegistry.register(plugin_module)

    # Plugin-owned resource://<ws>/<type>/<name> types (plugin-resource SPEC §4.2)
    # — registered LAST (codex MEDIUM): the resource Registry has no production
    # unregister path, so if a resource registration ran before a later publish
    # step that raised (e.g. PluginRegistry duplicate-slug), the types would leak
    # for a plugin whose boot never completed. By running after every other
    # fallible step, a failure upstream means resource types were never written.
    # Whole-batch register_all/1 so the plugin contributes ALL its types or none
    # (HIGH-5). A duplicate `<type>` OR `backend_component` (codex HIGH-1) is an
    # author/operator error — fail boot loud naming the plugin. Core types are
    # claimed at Registry.init/1 before any plugin boots, so a plugin can neither
    # shadow a core type nor alias a core backend.
    case Ezagent.Resource.FsResolver.Registry.register_all(plugin_module.resource_types()) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "#{inspect(plugin_module)} resource_types → #{inspect(reason)}"
    end

    :ok = Ezagent.Plugin.FlavorPublishHook.after_plugin_publish(plugin_module)

    :ok
  end

  # codex PR-5 HIGH-1 — a plugin may NOT register a scheme-level spawn
  # fn. `SpawnRegistry.register/2` is scheme-keyed and OVERWRITES, so
  # any plugin scheme spawn (even one naming a core scheme) hijacks
  # that scheme's dispatcher. Every scheme is core/domain-owned ⇒
  # there is no valid plugin spawn ⇒ any non-empty `spawns/0` is a
  # hard error.
  defp reject_spawns!(plugin_module) do
    case plugin_module.spawns() do
      [] ->
        :ok

      declared ->
        raise ArgumentError,
              "#{inspect(plugin_module)} declared spawns/0 = #{inspect(declared)}. " <>
                "A plugin may NOT register a scheme-level spawn fn — " <>
                "Ezagent.SpawnRegistry is scheme-keyed and OVERWRITES, so this " <>
                "would hijack a core scheme's dispatcher (invariant 8). All six " <>
                "URI schemes (#{Enum.join(@core_schemes, ", ")}) are owned by " <>
                "core/domain; spawns/0 is reserved and must return []. Extend an " <>
                "existing scheme via your Kind's type/name prefix " <>
                "(for example an entity agent URI), or register a " <>
                "Behavior on a core Kind instead."
    end
  end

  defp maybe_register_bridge_adapter(%{flavor: flavor, bridge_adapter: adapter})
       when is_binary(flavor) and is_atom(adapter) do
    if Code.ensure_loaded?(Ezagent.AgentBridge.AdapterRegistry) do
      :ok = apply(Ezagent.AgentBridge.AdapterRegistry, :register, [flavor, adapter])
    else
      :ok
    end
  end

  defp maybe_register_bridge_adapter(_decl), do: :ok

  # codex PR-5 MEDIUM-4 — every `agent_flavors/0` entry's `kind` must
  # implement `Ezagent.Kind` and `template_class` must implement
  # `Ezagent.Kind.Template`. The `:ezagent_plugin_check` gate checks
  # this at compile time; this is the defensive boot-time guard
  # (catches e.g. a hot-installed plugin that bypassed the gate).
  #
  # Reachability caveat: a flavor's `kind` may be a CORE/domain Kind
  # the plugin REUSES rather than owns (cc's flavor `kind` is
  # `Ezagent.Entity.Agent` from `ezagent_domain_session`). The plugin
  # cannot depend on a domain app that already depends on it (cycle),
  # so that module's beam is not on the plugin's standalone code path.
  # `assert_implements!` therefore behaviour-checks only modules it can
  # resolve; a non-module value and a resolvable-but-wrong-behaviour
  # module still hard-fail. A core/domain Kind always implements
  # `Ezagent.Kind` by construction — the value of this guard is
  # rejecting a plugin's OWN malformed flavor module.
  defp assert_agent_flavor!(plugin_module, %{
         flavor: flavor,
         kind: kind,
         template_class: template_class
       }) do
    assert_implements!(
      plugin_module,
      kind,
      Ezagent.Kind,
      "agent_flavors/0 (flavor #{inspect(flavor)})"
    )

    assert_implements!(
      plugin_module,
      template_class,
      Ezagent.Kind.Template,
      "agent_flavors/0 (flavor #{inspect(flavor)})"
    )

    :ok
  end

  defp assert_agent_flavor!(plugin_module, decl) do
    raise ArgumentError,
          "#{inspect(plugin_module)} declared a malformed agent_flavors/0 entry: " <>
            "#{inspect(decl)}. Each entry must be a map " <>
            "%{flavor: String.t(), kind: module(), template_class: module()}."
  end

  # ExternalMirror PR-EM-1 — runtime Grill-5 verification for an
  # `adapters/0` entry. Mirrors the `:ezagent_plugin_check` compiler
  # checks (defense in depth: catches a plugin hot-installed past the
  # build gate).
  #
  # Five checks per SPEC §5.1:
  # 1. adapter implements `@behaviour Ezagent.ExternalMirror.Adapter`
  # 2. binding implements `@behaviour Ezagent.ExternalMirror.Binding`
  # 3. `adapter.binding_module() == binding`
  # 4. `binding.adapter_module() == adapter`
  # 5. `adapter != binding` (structural — single module implementing
  #    both behaviours dissolves the boundary)
  defp assert_adapter_decl!(plugin_module, {adapter, binding})
       when is_atom(adapter) and is_atom(binding) do
    src = "adapters/0 entry #{inspect({adapter, binding})}"

    # P3-1 — the `{adapter, binding}` tuple is the `:push` shape. A
    # `:pull` adapter has no binding and MUST be declared bare (the
    # `is_atom/1` clause below). Reject a pull adapter wrapped in a tuple
    # so a plugin can't smuggle a dummy binding past the no-binding
    # invariant (which would write a BindingRegistry row for a pull
    # adapter at boot).
    if adapter_kind_of(adapter) == :pull do
      raise ArgumentError,
            "#{inspect(plugin_module)} #{src}: #{inspect(adapter)} is a :pull " <>
              "adapter (adapter_kind/0 == :pull) but is declared as a " <>
              "`{adapter, binding}` tuple. A pull adapter has NO binding — " <>
              "declare it as a BARE module (P3-1). Supplying a dummy binding " <>
              "would violate the no-binding invariant."
    end

    if adapter == binding do
      raise ArgumentError,
            "#{inspect(plugin_module)} #{src}: adapter and binding must be " <>
              "DIFFERENT modules. A single module implementing both behaviours " <>
              "dissolves the adapter/binding boundary (Grill-5 / SPEC §5.1)."
    end

    assert_implements!(plugin_module, adapter, Ezagent.ExternalMirror.Adapter, src)
    assert_implements!(plugin_module, binding, Ezagent.ExternalMirror.Binding, src)

    # Bidirectional declaration — both sides MUST name the other.
    # These calls reach the modules' own `binding_module/0` /
    # `adapter_module/0` answers; the system trusts the module over
    # the plugin's `adapters/0` tuple if they disagree (the tuple is
    # what the plugin author typed; the module's callback is the
    # behaviour-checked source of truth).
    #
    # `assert_implements!` silently tolerates unreachable modules
    # (reachability caveat — same as agent_flavors). If we land here
    # with an unreachable adapter/binding, calling
    # `adapter.binding_module()` would raise UndefinedFunctionError
    # with a confusing stack. Defensive guard: ensure both callbacks
    # are loadable BEFORE invoking. If either is missing, skip the
    # bidirectional check — the compiler gate is the primary defense
    # and will catch a real mismatch on the next compile. For PR-EM-1
    # plugin adapters this is moot — the plugin owns both modules
    # and they're always reachable — the guard keeps the runtime
    # path crash-free for edge cases (e.g. a hot-installed plugin
    # whose dependency hasn't loaded yet).
    if function_exported?(adapter, :binding_module, 0) and
         function_exported?(binding, :adapter_module, 0) do
      check_bidirectional!(plugin_module, adapter, binding, src)
    end

    :ok
  end

  # P3-1 — a BARE adapter module is the `:pull` declaration shape.
  # A pull adapter has no binding (no per-binding transport), so it is
  # declared as a single module rather than a tuple. Validate it is a
  # genuine `:pull` adapter implementing the pull contract; a bare
  # `:push` module is malformed (push needs the `{adapter, binding}`
  # tuple). `AdapterRegistry.register/1` enforces the per-kind required
  # callbacks (`render/2` + `cap_subject/0` for pull) at registration.
  defp assert_adapter_decl!(plugin_module, adapter)
       when is_atom(adapter) and not is_nil(adapter) and not is_boolean(adapter) do
    src = "adapters/0 entry #{inspect(adapter)}"

    # Only a loadable module implementing `@behaviour
    # Ezagent.ExternalMirror.Adapter` is a valid bare (:pull) declaration.
    # A bogus atom (`:not_a_tuple`) or a module that isn't an adapter is
    # MALFORMED — delegate to the catch-all clause for a clear message.
    if bare_pull_candidate?(adapter) do
      assert_implements!(plugin_module, adapter, Ezagent.ExternalMirror.Adapter, src)

      case adapter_kind_of(adapter) do
        :pull ->
          :ok

        :push ->
          raise ArgumentError,
                "#{inspect(plugin_module)} #{src}: #{inspect(adapter)} is a :push " <>
                  "adapter (adapter_kind/0 defaults to :push) declared as a BARE " <>
                  "module. The bare-module shape is reserved for :pull adapters; a " <>
                  ":push adapter MUST be declared as a `{adapter_module, " <>
                  "binding_module}` tuple (P3-1 / SPEC §5.1)."
      end
    else
      raise_malformed_adapter_decl!(plugin_module, adapter)
    end
  end

  defp assert_adapter_decl!(plugin_module, decl) do
    raise_malformed_adapter_decl!(plugin_module, decl)
  end

  defp raise_malformed_adapter_decl!(plugin_module, decl) do
    raise ArgumentError,
          "#{inspect(plugin_module)} declared a malformed adapters/0 entry: " <>
            "#{inspect(decl)}. Each entry must be a `{adapter_module :: " <>
            "module(), binding_module :: module()}` tuple (:push) or a bare " <>
            "`adapter_module :: module()` (:pull)."
  end

  # A bare atom is a (pull) adapter-declaration CANDIDATE only when it is
  # a loadable module that implements `@behaviour
  # Ezagent.ExternalMirror.Adapter`. Anything else (a stray atom like
  # `:not_a_tuple`, or a module that isn't an adapter) is malformed.
  defp bare_pull_candidate?(adapter) when is_atom(adapter) do
    match?({:module, ^adapter}, Code.ensure_compiled(adapter)) and
      behaviour_present?(adapter, Ezagent.ExternalMirror.Adapter)
  end

  # Resolve an adapter's kind via `Ezagent.ExternalMirror.Adapter.kind_of/1`.
  # Uses `apply/3` because `Ezagent.ExternalMirror.Adapter` lives in
  # `ezagent_domain_external_mirror`, downstream of `ezagent_core` — a
  # direct call would emit "module not available" at core compile (same
  # rationale as the `apply/3` registry calls in `publish_adapters!/2`).
  defp adapter_kind_of(adapter) when is_atom(adapter) do
    apply(Ezagent.ExternalMirror.Adapter, :kind_of, [adapter])
  end

  defp check_bidirectional!(plugin_module, adapter, binding, src) do
    declared_binding = adapter.binding_module()
    declared_adapter = binding.adapter_module()

    cond do
      declared_binding != binding ->
        raise ArgumentError,
              "#{inspect(plugin_module)} #{src}: " <>
                "#{inspect(adapter)}.binding_module() returned " <>
                "#{inspect(declared_binding)}, but the adapters/0 entry pairs it " <>
                "with #{inspect(binding)}. Grill-5 mandates bidirectional 1:1 " <>
                "declaration (SPEC §5.1)."

      declared_adapter != adapter ->
        raise ArgumentError,
              "#{inspect(plugin_module)} #{src}: " <>
                "#{inspect(binding)}.adapter_module() returned " <>
                "#{inspect(declared_adapter)}, but the adapters/0 entry pairs it " <>
                "with #{inspect(adapter)}. Grill-5 mandates bidirectional 1:1 " <>
                "declaration (SPEC §5.1)."

      true ->
        :ok
    end
  end

  # ExternalMirror PR-EM-1 (codex r1 HIGH-1) — all-or-nothing
  # registration:
  #
  # Phase 1: validate every entry (Grill-5 + intra-batch duplicate
  #          detection). Raises before touching any registry on bad
  #          input. If two pairs in this plugin's `adapters/0` claim
  #          the same `adapter_id`, the batch is rejected (single
  #          source of truth — a plugin can't accidentally fight
  #          itself across two declarations).
  #
  # Phase 2: insert into both registries. Each successful insert is
  #          tracked so Phase 3 can roll back on failure.
  #
  # Phase 3: rollback. On any insert failure, delete every row this
  #          boot attempt wrote (best-effort — `__delete__/1` is
  #          idempotent), then re-raise the original error.
  #
  # Concurrency note: Phase 2 uses `:ets.insert_new/2` (atomic) in
  # both registries — a concurrent boot for the SAME `adapter_id`
  # will be detected and raise (not silently overwrite). This is
  # the codex r1 HIGH-2 fix.
  #
  # Why `apply/3`: `Ezagent.ExternalMirror.{Adapter,Binding}Registry`
  # live in `ezagent_domain_external_mirror`, downstream of
  # `ezagent_core`. A direct call would emit "module not available"
  # warnings at core's compile time.
  defp publish_adapters!(_plugin_module, []), do: :ok

  defp publish_adapters!(plugin_module, decls) when is_list(decls) do
    # Phase 1 — validate every entry, including intra-batch duplicates.
    Enum.each(decls, &assert_adapter_decl!(plugin_module, &1))

    intra_batch_dup_check!(plugin_module, decls)

    # Phase 2 — write atomically; track INSERT-ONLY receipts so the
    # rollback path (Phase 3) deletes only what THIS boot attempt
    # wrote, never rows that already existed (codex r2 HIGH-2 fix).
    #
    # The receipts list is built imperatively via a ref-backed
    # process-dictionary key so a `rescue` (which loses the reduce
    # accumulator) can still read it. Cleared in the `after` block
    # so a passing boot leaves no residual state.
    receipts_ref = make_ref()
    Process.put({:em_pr1_receipts, receipts_ref}, [])

    try do
      Enum.each(decls, fn decl ->
        # P3-1 — branch the registry writes by declaration shape:
        #   {adapter, binding}  → :push: write BOTH registries.
        #   bare adapter module → :pull: write AdapterRegistry ONLY (no
        #                         binding — the no-binding invariant).
        case decl do
          {adapter_module, binding_module} ->
            adapter_id = adapter_module.adapter_id()

            adapter_result =
              apply(Ezagent.ExternalMirror.AdapterRegistry, :register, [adapter_module])

            record_receipt!(receipts_ref, {:adapter, adapter_id, adapter_module, adapter_result})

            binding_result =
              apply(Ezagent.ExternalMirror.BindingRegistry, :register_module, [
                adapter_id,
                binding_module
              ])

            record_receipt!(receipts_ref, {:binding, adapter_id, binding_module, binding_result})

          adapter_module when is_atom(adapter_module) ->
            adapter_id = adapter_module.adapter_id()

            adapter_result =
              apply(Ezagent.ExternalMirror.AdapterRegistry, :register, [adapter_module])

            record_receipt!(receipts_ref, {:adapter, adapter_id, adapter_module, adapter_result})
        end
      end)

      :ok
    rescue
      e ->
        # Phase 3 — rollback ONLY the registries this attempt
        # inserted into (receipts where the registry returned `:ok`,
        # not `{:ok, :already_present}`). Pre-existing rows survive.
        rollback_adapters_from_receipts!(Process.get({:em_pr1_receipts, receipts_ref}, []))
        reraise e, __STACKTRACE__
    after
      Process.delete({:em_pr1_receipts, receipts_ref})
    end
  end

  defp record_receipt!(ref, receipt) do
    Process.put({:em_pr1_receipts, ref}, [receipt | Process.get({:em_pr1_receipts, ref}, [])])
  end

  # Catches the case where a plugin's adapters/0 has TWO entries
  # claiming the same adapter_id (would also be caught by the
  # registry's atomic insert_new, but caught here we can fail in
  # Phase 1 — before any write — so no rollback needed for that
  # case. Defense in depth.)
  defp intra_batch_dup_check!(plugin_module, decls) do
    ids =
      Enum.map(decls, fn decl ->
        # P3-1 — extract the adapter module from either declaration shape.
        adapter_module =
          case decl do
            {adapter_module, _binding} -> adapter_module
            adapter_module when is_atom(adapter_module) -> adapter_module
          end

        {adapter_module.adapter_id(), adapter_module}
      end)

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      [{dup_id, _} | _] ->
        raise ArgumentError,
              "#{inspect(plugin_module)} adapters/0 declares two entries with " <>
                "the same adapter_id #{inspect(dup_id)}. Each adapter_id must " <>
                "be unique within a plugin (per SPEC §5.2)."
    end
  end

  # codex r2 HIGH-2 — receipts-driven rollback. Only deletes rows
  # whose receipt was `:ok` (the registry's `:insert_new` returned
  # true, meaning THIS attempt wrote the row). Skips rows whose
  # receipt was `{:ok, :already_present}` — those existed before
  # and aren't ours to delete.
  #
  # Belt-and-suspenders: re-verify the registry still holds OUR
  # module before deleting (a concurrent sibling write would have
  # rejected via the `insert_new` atomicity, so this is defense in
  # depth against a hypothetical race we missed).
  defp rollback_adapters_from_receipts!(receipts) do
    Enum.each(receipts, fn
      {:adapter, adapter_id, adapter_module, :ok} ->
        case apply(Ezagent.ExternalMirror.AdapterRegistry, :lookup, [adapter_id]) do
          {:ok, ^adapter_module} ->
            apply(Ezagent.ExternalMirror.AdapterRegistry, :__delete__, [adapter_id])

          _ ->
            :ok
        end

      {:binding, adapter_id, binding_module, :ok} ->
        case apply(Ezagent.ExternalMirror.BindingRegistry, :lookup, [adapter_id]) do
          {:ok, ^binding_module} ->
            apply(Ezagent.ExternalMirror.BindingRegistry, :__delete__, [adapter_id])

          _ ->
            :ok
        end

      # `{:ok, :already_present}` receipts — leave alone, this
      # attempt didn't write that row.
      _ ->
        :ok
    end)

    :ok
  end

  defp assert_implements!(plugin_module, module, behaviour, source) do
    cond do
      not is_atom(module) ->
        raise ArgumentError,
              "#{inspect(plugin_module)} #{source} declares #{inspect(module)}, " <>
                "which is not a module."

      not match?({:module, ^module}, Code.ensure_compiled(module)) ->
        # Unreachable from this plugin's code path — a reused
        # core/domain Kind. Cannot behaviour-check; tolerate (see the
        # reachability caveat above).
        :ok

      not behaviour_present?(module, behaviour) ->
        raise ArgumentError,
              "#{inspect(plugin_module)} #{source} declares #{inspect(module)}, " <>
                "which does not implement the #{inspect(behaviour)} behaviour."

      true ->
        :ok
    end
  end

  defp behaviour_present?(module, behaviour) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(behaviour)
  rescue
    _ -> false
  end

  # codex PR-5 MEDIUM-5 — `config_surface/0` is `:route | :flavor |
  # nil` in V1. `:form` (auto-rendered settings persisted to a store
  # that does not exist yet) is V2 — reject it. A malformed map (or
  # any non-conforming value) is also rejected so it cannot reach
  # `plugins_live` and crash `/plugins`. Mirrors the
  # `:ezagent_plugin_check` gate's compile-time check.
  defp assert_config_surface!(_plugin_module, nil), do: :ok

  defp assert_config_surface!(_plugin_module, %{kind: :route, path: path, label: label})
       when is_binary(path) and is_binary(label),
       do: :ok

  defp assert_config_surface!(_plugin_module, %{kind: :flavor, flavor: flavor, label: label})
       when is_binary(flavor) and is_binary(label),
       do: :ok

  defp assert_config_surface!(plugin_module, %{kind: :form} = surface) do
    raise ArgumentError,
          "#{inspect(plugin_module)} declared a `:form` config_surface/0 " <>
            "(#{inspect(surface)}). The plugin settings store is V2 — `:form` " <>
            "is rejected in V1. V1 config_surface/0 is :route | :flavor | nil " <>
            "(SPEC §6.1)."
  end

  defp assert_config_surface!(plugin_module, surface) do
    raise ArgumentError,
          "#{inspect(plugin_module)} declared a malformed config_surface/0: " <>
            "#{inspect(surface)}. V1 config_surface/0 is one of " <>
            "%{kind: :route, path: String.t(), label: String.t()}, " <>
            "%{kind: :flavor, flavor: String.t(), label: String.t()}, or nil " <>
            "(SPEC §6.1)."
  end
end
