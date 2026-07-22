defmodule Mix.Tasks.Compile.EzagentPluginCheck do
  use Mix.Task.Compiler

  @shortdoc "The non-bypassable app-level gate for the Ezagent.Plugin contract"

  @moduledoc """
  `:ezagent_plugin_check` — the non-bypassable app-level gate for the
  `Ezagent.Plugin` contract (SPEC §3.2).

  SPEC `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`.

  `use Ezagent.Plugin` + its `@after_compile` (SPEC §3.1) catch the
  common plugin-LOCAL mistakes fast — but they are (a) opt-in (a plugin
  app that never `use`s the behaviour bypasses everything) and (b)
  unable to safely dereference sibling kind/behavior/template modules
  in an umbrella (codex HIGH-1 / HIGH-3). This Mix compiler is the
  second enforcement layer: wired into a plugin app's `mix.exs`
  `compilers:` list, it runs after the WHOLE app has compiled and does
  the cross-module checks. A non-conforming plugin app fails to build.

  ## Wiring (added at migration time — PR-2/3, not PR-1)

  A migrating `ezagent_plugin_*` app adds, in its `mix.exs`:

      def project do
        [
          ...,
          compilers: [:ezagent_plugin_check] ++ Mix.compilers()
        ]
      end

      def application do
        [
          mod: {EzagentPluginCc.Application, []},
          env: [ezagent_plugin: EzagentPluginCc],
          extra_applications: [:logger]
        ]
      end

  The `:ezagent_plugin` app-env key (read here via
  `Application.get_env/3`, with a `Mix.Project` config fallback for a
  fresh build where the application is not loaded yet) names the
  plugin contract module.

  ## Behavior when no `:ezagent_plugin` key is set

  - **An `ezagent_plugin_*` app with NO `:ezagent_plugin` key → the
    build FAILS** (codex PR-5 HIGH-3). Detection is by the
    `Mix.Project.config()[:app]` name prefix. The original "no-op
    pass" here was the bypass: a plugin app could include the
    compiler but omit `env: [ezagent_plugin: ...]` and skip ALL
    checks. Every `ezagent_plugin_*` app MUST name its contract
    module via the `:ezagent_plugin` env key; a missing key is itself
    a contract violation.
  - **A non-`ezagent_plugin_*` app with no key → no-op `{:ok, []}`**
    (correct — `ezagent_core` runs this compiler harmlessly, and a
    partial migration that lands the `compilers:` line before the
    plugin module never blocks a non-plugin app).

  ## Checks (SPEC §3.2 + codex PR-5)

  1. The app declares a plugin module (the `:ezagent_plugin` key) —
     **mandatory for an `ezagent_plugin_*` app** (HIGH-3).
  2. That module `use`s `Ezagent.Plugin` (`@behaviour Ezagent.Plugin`
     present).
  3. Every declared kind / behavior / template module exists and
     implements its own behaviour (`Ezagent.Kind` /
     `Ezagent.ActionSet` / `Ezagent.Kind.Template`).
  4. Every `agent_flavors/0` entry's `kind` implements `Ezagent.Kind`
     and `template_class` implements `Ezagent.Kind.Template`
     (codex PR-5 MEDIUM-4).
  5. `spawns/0` is empty — a plugin may not own a scheme-level spawn
     (codex PR-5 HIGH-1).
  6. `config_surface/0` is `:route | :flavor | nil`; `:form` and
     malformed maps are rejected (codex PR-5 MEDIUM-5).
  7. The app source does not call `*Registry.register` /
     `RoutingRegistry.declare_table` directly — registration goes
     through `Ezagent.Plugin.boot/1` (grep gate). **Build-time Mix
     tasks (`<elixirc_path>/mix/tasks/**.ex`) are EXEMPT** — a Mix task
     is dev/build tooling invoked via `mix <task>`, never loaded into
     the running app's boot path, so seeding a registry there is
     legitimate (the target of this check is RUNTIME plugin code that
     bypasses `boot/1`).

  Any failure → the compiler returns `{:error, [diagnostic]}`, which
  fails the build with a precise diagnostic.
  """

  # codex r1 MEDIUM-1 (ExternalMirror PR-EM-1): include the
  # `Ezagent.ExternalMirror.AdapterRegistry` and
  # `Ezagent.ExternalMirror.BindingRegistry` in the gate — without
  # this, a plugin could bypass `adapters/0` (and the Grill-5
  # bidirectional checks the compiler runs over it) by calling
  # `Ezagent.ExternalMirror.AdapterRegistry.register/1` directly.
  # The registries themselves now reject calls from modules that
  # don't implement the relevant behaviour (defense in depth), but
  # the compile-time grep keeps the plugin contract — "declare,
  # don't call" (SPEC §3.2) — visible and enforceable at build.
  @registry_grep_pattern ~r/\b(?:Ezagent\.)?(?:ExternalMirror\.)?(?:Adapter|Binding|Behavior|Spawn|Template|Plugin|AgentFlavor|Routing)Registry\.(?:register|register_module|declare_table)\b/

  # Build-time Mix tasks (`<elixirc_path>/mix/tasks/**.ex`, compiled to
  # `Mix.Tasks.*`) are EXEMPT from the check-7 grep. A Mix task is
  # dev/build tooling invoked via `mix <task>` — it is NEVER loaded into
  # the running application's boot path, so seeding a registry there (e.g.
  # `mix world.e2e.fixtures` seeds `Ezagent.PluginRegistry` to project the
  # Tier-1 fixture manifest without a full umbrella boot) is legitimate and
  # is NOT the bypass this check guards against. The check's real target is
  # RUNTIME plugin modules that skip the sanctioned `Ezagent.Plugin.boot/1`
  # registration path (SPEC §3.2 — "declare, don't call").
  @mix_task_path_pattern ~r{(^|/)mix/tasks/}

  @impl Mix.Task.Compiler
  def run(_argv) do
    plugin_module = configured_plugin_module()

    cond do
      not is_nil(plugin_module) ->
        diagnostics =
          []
          |> check_uses_behaviour(plugin_module)
          |> check_declared_modules(plugin_module)
          |> check_agent_flavors(plugin_module)
          |> check_adapters(plugin_module)
          |> check_spawns_empty(plugin_module)
          |> check_config_surface(plugin_module)
          |> check_no_direct_registry_calls()
          |> check_required_caps_callbacks(plugin_module)
          |> check_required_caps_values_struct(plugin_module)

        if diagnostics == [] do
          {:ok, []}
        else
          Enum.each(diagnostics, &print_diagnostic/1)
          {:error, diagnostics}
        end

      ezagent_plugin_app?() ->
        # codex PR-5 HIGH-3 — an `ezagent_plugin_*` app that wires this
        # compiler but omits the `:ezagent_plugin` env key would
        # otherwise bypass EVERY check. That is the hole. The key is
        # mandatory for a plugin app; a missing key FAILS the build.
        diag =
          diagnostic(
            "this is an `ezagent_plugin_*` app (#{inspect(current_app())}) but it " <>
              "declares NO plugin contract module. Add `env: [ezagent_plugin: " <>
              "<YourPlugin>]` to `application/0` in mix.exs — the :ezagent_plugin " <>
              "key names the module that `use`s Ezagent.Plugin. Without it the " <>
              ":ezagent_plugin_check gate cannot run and the plugin authoring " <>
              "contract is unenforced (SPEC §3.2)."
          )

        print_diagnostic(diag)
        {:error, [diag]}

      true ->
        # Non-`ezagent_plugin_*` app with no key (e.g. ezagent_core) —
        # genuine no-op pass.
        {:ok, []}
    end
  end

  # --- is the app under compilation an ezagent_plugin_* app? -------------

  defp current_app, do: Keyword.get(Mix.Project.config(), :app)

  defp ezagent_plugin_app? do
    case current_app() do
      app when is_atom(app) -> String.starts_with?(Atom.to_string(app), "ezagent_plugin_")
      _ -> false
    end
  end

  # --- which plugin module does this app declare? -----------------------

  # Read the `:ezagent_plugin` app-env key the plugin app's `mix.exs`
  # sets in `application/0`'s `env:`. Prefer the loaded application
  # environment (`Application.get_env/3` — the `.app` file's `env`
  # populates this once the app is built); fall back to invoking the
  # `application/0` callback on the current project module directly
  # (covers a fresh build where the `.app` file does not exist yet,
  # and `Mix.Project.in_project/4` test contexts where the fixture
  # app is never loaded).
  defp configured_plugin_module do
    app = Keyword.fetch!(Mix.Project.config(), :app)

    Application.get_env(app, :ezagent_plugin) || from_mix_project()
  end

  # `:application` is NOT a key of `Mix.Project.config/0` (that returns
  # `project/0`); it is the separate `application/0` project-module
  # callback. Invoke it on the project module to read the `env:` list.
  defp from_mix_project do
    project_module = Mix.Project.get()

    cond do
      is_nil(project_module) ->
        nil

      function_exported?(project_module, :application, 0) ->
        project_module.application()
        |> Keyword.get(:env, [])
        |> Keyword.get(:ezagent_plugin)

      true ->
        nil
    end
  end

  # --- check 2 — the module `use`s Ezagent.Plugin -----------------------

  defp check_uses_behaviour(diagnostics, plugin_module) do
    cond do
      not ensure_compiled?(plugin_module) ->
        [
          diagnostic(
            "the :ezagent_plugin app-env key names #{inspect(plugin_module)}, " <>
              "but that module does not exist / failed to compile."
          )
          | diagnostics
        ]

      not uses_plugin_behaviour?(plugin_module) ->
        [
          diagnostic(
            "#{inspect(plugin_module)} (the :ezagent_plugin module) does not " <>
              "`use Ezagent.Plugin`. Every plugin contract module must " <>
              "`use Ezagent.Plugin` so the behaviour + defaults + " <>
              "@after_compile validation apply (SPEC §3.1)."
          )
          | diagnostics
        ]

      true ->
        diagnostics
    end
  end

  defp uses_plugin_behaviour?(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Ezagent.Plugin in behaviours
  end

  # --- check 3 — declared modules exist + implement their behaviour -----

  defp check_declared_modules(diagnostics, plugin_module) do
    if uses_plugin_behaviour?(plugin_module) and ensure_compiled?(plugin_module) do
      diagnostics
      |> check_modules(plugin_module.kinds(), Ezagent.Kind, "kinds/0")
      |> check_modules(
        Enum.map(plugin_module.behaviors(), fn {_kind, _action, b} -> b end),
        Ezagent.ActionSet,
        "behaviors/0"
      )
      |> check_modules(
        plugin_module.template_classes(),
        Ezagent.Kind.Template,
        "template_classes/0"
      )
    else
      diagnostics
    end
  rescue
    e ->
      [
        diagnostic(
          "calling a declaration callback on #{inspect(plugin_module)} raised: " <>
            Exception.message(e)
        )
        | diagnostics
      ]
  end

  # `expected_behaviour` is always a module here. Each declared module
  # must (a) exist / be compiled and (b) implement that behaviour.
  defp check_modules(diagnostics, modules, expected_behaviour, source) do
    Enum.reduce(modules, diagnostics, fn module, acc ->
      cond do
        not ensure_compiled?(module) ->
          [
            diagnostic(
              "#{source} declares #{inspect(module)}, which does not exist / " <>
                "failed to compile."
            )
            | acc
          ]

        not implements_behaviour?(module, expected_behaviour) ->
          [
            diagnostic(
              "#{source} declares #{inspect(module)}, which does not implement " <>
                "the #{inspect(expected_behaviour)} behaviour."
            )
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp implements_behaviour?(module, behaviour) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    cond do
      # Phase 3 deletion (2026-05-28): the `@behaviour Ezagent.ActionSet`
      # alternative is no longer accepted. Every Behavior MUST opt in
      # via `use Ezagent.ActionSet`, which emits the `__behavior__?/0`
      # marker the gate consults below.
      behaviour == Ezagent.ActionSet ->
        new_style_behavior?(module)

      behaviour in behaviours ->
        true

      true ->
        false
    end
  rescue
    _ -> false
  end

  defp new_style_behavior?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :__behavior__?, 0) and
      apply(module, :__behavior__?, [])
  rescue
    _ -> false
  end

  # --- check 4 — agent_flavors/0 kind + template_class implement their
  #     behaviours (codex PR-5 MEDIUM-4) --------------------------------
  #
  # The merged contract validated agent_flavors/0 with
  # `expected_behaviour: nil` — it only checked the modules EXIST, not
  # that `decl.kind` implements `Ezagent.Kind` and `decl.template_class`
  # implements `Ezagent.Kind.Template`. A flavor declaring a non-Kind
  # module passed the gate, then the resolver mis-spawned it.
  #
  # Compile-order caveat (the codex HIGH-3 lesson): an agent flavor's
  # `kind` may legitimately be a CORE/domain Kind the plugin REUSES
  # rather than owns — e.g. cc's flavor `kind` is `Ezagent.Entity.Agent`
  # from `ezagent_domain_session`, and a plugin cannot depend on a domain
  # app that already depends on it (cycle). Such a module is simply not
  # on the plugin's codepath at its own compile time. So the gate
  # behaviour-checks only the modules it CAN resolve; an unreachable
  # one is deferred to `Ezagent.Plugin.boot/1`'s `assert_agent_flavor!`
  # (runtime — every app is loaded, the SPEC-mandated hard guarantee).
  # A reachable module that does NOT implement the behaviour still
  # hard-fails the build.
  defp check_agent_flavors(diagnostics, plugin_module) do
    if uses_plugin_behaviour?(plugin_module) and ensure_compiled?(plugin_module) do
      Enum.reduce(plugin_module.agent_flavors(), diagnostics, fn decl, acc ->
        case decl do
          %{flavor: flavor, kind: kind, template_class: tc} ->
            src = "agent_flavors/0 (flavor #{inspect(flavor)})"

            acc =
              acc
              |> check_flavor_module(kind, Ezagent.Kind, src)
              |> check_flavor_module(tc, Ezagent.Kind.Template, src)

            case Map.get(decl, :bridge_adapter) do
              nil -> acc
              adapter -> check_flavor_module(acc, adapter, Ezagent.AgentBridge.Adapter, src)
            end

          other ->
            [
              diagnostic(
                "agent_flavors/0 has a malformed entry #{inspect(other)} — each " <>
                  "entry must be %{flavor: String.t(), kind: module(), " <>
                  "template_class: module()}."
              )
              | acc
            ]
        end
      end)
    else
      diagnostics
    end
  rescue
    _ -> diagnostics
  end

  # An agent-flavor module: if reachable at compile time it MUST
  # implement the behaviour (hard fail otherwise); if unreachable
  # (a reused core/domain Kind off the plugin's codepath) the check
  # is deferred to `boot/1`'s runtime `assert_agent_flavor!`.
  defp check_flavor_module(diagnostics, module, behaviour, source) do
    cond do
      not is_atom(module) ->
        [
          diagnostic("#{source} declares #{inspect(module)}, which is not a module.")
          | diagnostics
        ]

      not ensure_compiled?(module) ->
        # Not on this plugin's codepath at compile time — deferred to
        # the runtime gate. Not a build failure.
        diagnostics

      not implements_behaviour?(module, behaviour) ->
        [
          diagnostic(
            "#{source} declares #{inspect(module)}, which does not implement " <>
              "the #{inspect(behaviour)} behaviour."
          )
          | diagnostics
        ]

      true ->
        diagnostics
    end
  end

  # --- check 4b — adapters/0 Grill-5 (ExternalMirror PR-EM-1) -----------
  #
  # SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  # §5.1: each `{adapter, binding}` entry must satisfy
  #
  #   (a) adapter implements `@behaviour Ezagent.ExternalMirror.Adapter`
  #   (b) binding implements `@behaviour Ezagent.ExternalMirror.Binding`
  #   (c) `adapter.binding_module() == binding`
  #   (d) `binding.adapter_module() == adapter`
  #   (e) `adapter != binding` (distinct modules — a single module
  #       implementing both behaviours dissolves the boundary)
  #
  # All five run at compile time so a malformed plugin fails the build,
  # not the runtime. `Ezagent.Plugin.boot/1` re-verifies the same set
  # at runtime as defense-in-depth (catches a plugin hot-installed
  # past the gate).
  #
  # Reachability caveat (same as `check_agent_flavors/2`): if a
  # declared module is NOT on the plugin's codepath (e.g. core/domain
  # module the plugin reuses) we cannot resolve it — the runtime
  # `assert_adapter_decl!` is the backstop. A reachable-but-wrong
  # module hard-fails the build.
  defp check_adapters(diagnostics, plugin_module) do
    if uses_plugin_behaviour?(plugin_module) and ensure_compiled?(plugin_module) do
      Enum.reduce(plugin_module.adapters(), diagnostics, fn entry, acc ->
        check_adapter_entry(acc, plugin_module, entry)
      end)
    else
      diagnostics
    end
  rescue
    _ -> diagnostics
  end

  defp check_adapter_entry(diagnostics, _plugin_module, {adapter, binding})
       when is_atom(adapter) and is_atom(binding) do
    src = "adapters/0 entry #{inspect({adapter, binding})}"

    diagnostics
    |> check_adapter_push_kind(adapter, src)
    |> check_adapter_distinct(adapter, binding, src)
    |> check_adapter_module(adapter, Ezagent.ExternalMirror.Adapter, src)
    |> check_adapter_module(binding, Ezagent.ExternalMirror.Binding, src)
    |> check_adapter_bidirectional(adapter, binding, src)
  end

  # P3-1 — a BARE adapter module is the `:pull` declaration shape (no
  # binding; pull adapters have no per-binding transport). Validate the
  # module implements the Adapter behaviour AND resolves to kind `:pull`;
  # a bare `:push` module is malformed (push needs the tuple).
  defp check_adapter_entry(diagnostics, _plugin_module, adapter)
       when is_atom(adapter) and not is_nil(adapter) and not is_boolean(adapter) do
    src = "adapters/0 entry #{inspect(adapter)}"

    cond do
      not ensure_compiled?(adapter) ->
        # Not on the plugin's compile-time codepath — defer to runtime
        # `assert_adapter_decl!`. (Reachability caveat, same as the tuple
        # path's `check_adapter_module`.)
        diagnostics

      not implements_behaviour?(adapter, Ezagent.ExternalMirror.Adapter) ->
        [
          diagnostic(
            "#{src}: a bare-module entry must implement the " <>
              "#{inspect(Ezagent.ExternalMirror.Adapter)} behaviour. " <>
              "#{inspect(adapter)} does not."
          )
          | diagnostics
        ]

      adapter_kind_of(adapter) != :pull ->
        [
          diagnostic(
            "#{src}: #{inspect(adapter)} is a :push adapter declared as a BARE " <>
              "module. The bare-module shape is reserved for :pull adapters; a " <>
              ":push adapter MUST be declared as a `{adapter_module, " <>
              "binding_module}` tuple (P3-1 / SPEC §5.1)."
          )
          | diagnostics
        ]

      true ->
        diagnostics
    end
  end

  defp check_adapter_entry(diagnostics, _plugin_module, malformed) do
    [
      diagnostic(
        "adapters/0 has a malformed entry #{inspect(malformed)} — each entry " <>
          "must be a `{adapter_module :: module(), binding_module :: module()}` " <>
          "tuple (:push) or a bare `adapter_module :: module()` (:pull)."
      )
      | diagnostics
    ]
  end

  # P3-1 — reject a `:pull` adapter wrapped in a `{adapter, binding}`
  # tuple. A pull adapter has no binding; pairing it with one (even a
  # dummy) would write a BindingRegistry row at boot, violating the
  # no-binding invariant. The compiler mirrors the runtime
  # `assert_adapter_decl!` guard.
  defp check_adapter_push_kind(diagnostics, adapter, src) do
    if ensure_compiled?(adapter) and
         implements_behaviour?(adapter, Ezagent.ExternalMirror.Adapter) and
         adapter_kind_of(adapter) == :pull do
      [
        diagnostic(
          "#{src}: #{inspect(adapter)} is a :pull adapter (adapter_kind/0 == " <>
            ":pull) declared as a `{adapter, binding}` tuple. A pull adapter " <>
            "has NO binding — declare it as a BARE module (P3-1)."
        )
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  # Resolve an adapter module's kind. `Ezagent.ExternalMirror.Adapter`
  # lives downstream of core; guard the call behind `ensure_compiled?`
  # (callers already do) and `apply/3` to avoid a compile-time module
  # reference.
  defp adapter_kind_of(adapter) when is_atom(adapter) do
    apply(Ezagent.ExternalMirror.Adapter, :kind_of, [adapter])
  rescue
    _ -> :push
  end

  defp check_adapter_distinct(diagnostics, adapter, binding, src) when adapter == binding do
    [
      diagnostic(
        "#{src}: adapter and binding must be DIFFERENT modules. A single module " <>
          "implementing both behaviours dissolves the adapter/binding boundary " <>
          "(Grill-5 / SPEC §5.1)."
      )
      | diagnostics
    ]
  end

  defp check_adapter_distinct(diagnostics, _adapter, _binding, _src), do: diagnostics

  # An adapters/0 module: if reachable at compile time it MUST
  # implement the behaviour (hard fail otherwise); if unreachable
  # the check is deferred to runtime `assert_adapter_decl!`.
  defp check_adapter_module(diagnostics, module, behaviour, src) do
    cond do
      not is_atom(module) ->
        [
          diagnostic("#{src} declares #{inspect(module)}, which is not a module.")
          | diagnostics
        ]

      not ensure_compiled?(module) ->
        # Not on plugin's compile-time codepath — defer to runtime gate.
        diagnostics

      not implements_behaviour?(module, behaviour) ->
        [
          diagnostic(
            "#{src} declares #{inspect(module)}, which does not implement the " <>
              "#{inspect(behaviour)} behaviour."
          )
          | diagnostics
        ]

      true ->
        diagnostics
    end
  end

  # Bidirectional declaration (Grill-5 c + d). Only verifies when
  # BOTH modules are resolvable AND implement the right behaviour
  # (otherwise the earlier checks already produced a diagnostic for
  # the offending side, and calling `adapter.binding_module()` on a
  # non-conforming module would raise UndefinedFunctionError).
  defp check_adapter_bidirectional(diagnostics, adapter, binding, src) do
    if ensure_compiled?(adapter) and ensure_compiled?(binding) and
         implements_behaviour?(adapter, Ezagent.ExternalMirror.Adapter) and
         implements_behaviour?(binding, Ezagent.ExternalMirror.Binding) do
      diagnostics
      |> maybe_diag_mismatch(
        adapter,
        :binding_module,
        binding,
        src,
        "Grill-5 mandates bidirectional 1:1 declaration (SPEC §5.1)."
      )
      |> maybe_diag_mismatch(
        binding,
        :adapter_module,
        adapter,
        src,
        "Grill-5 mandates bidirectional 1:1 declaration (SPEC §5.1)."
      )
    else
      diagnostics
    end
  rescue
    e ->
      [
        diagnostic("#{src}: calling bidirectional callbacks raised: " <> Exception.message(e))
        | diagnostics
      ]
  end

  defp maybe_diag_mismatch(diagnostics, mod, fun, expected, src, suffix) do
    case apply(mod, fun, []) do
      ^expected ->
        diagnostics

      actual ->
        [
          diagnostic(
            "#{src}: #{inspect(mod)}.#{fun}() returned #{inspect(actual)}, " <>
              "but the adapters/0 entry pairs it with #{inspect(expected)}. " <>
              suffix
          )
          | diagnostics
        ]
    end
  end

  # --- check 5 — spawns/0 is empty (codex PR-5 HIGH-1) ------------------
  #
  # `Ezagent.SpawnRegistry.register/2` is scheme-keyed and OVERWRITES.
  # A plugin declaring `{"entity", fun}` passed the old scheme allowlist
  # yet took ownership of ALL `entity://` spawning — invariant 8
  # violation. Every scheme is core-owned ⇒ no valid plugin spawn ⇒
  # spawns/0 MUST be empty.
  defp check_spawns_empty(diagnostics, plugin_module) do
    if uses_plugin_behaviour?(plugin_module) and ensure_compiled?(plugin_module) do
      case plugin_module.spawns() do
        [] ->
          diagnostics

        declared ->
          [
            diagnostic(
              "spawns/0 declares #{inspect(declared)} — a plugin may NOT register " <>
                "a scheme-level spawn fn. SpawnRegistry is scheme-keyed and " <>
                "OVERWRITES, so this hijacks a core scheme's dispatcher " <>
                "(invariant 8). All six URI schemes are core/domain-owned; " <>
                "spawns/0 is reserved and must return []. Extend a scheme via your " <>
                "Kind's type/name prefix, or register a Behavior on a core Kind " <>
                "(SPEC §5.8 — the feishu scheme deletion / codex PR-5 HIGH-1)."
            )
            | diagnostics
          ]
      end
    else
      diagnostics
    end
  rescue
    _ -> diagnostics
  end

  # --- check 6 — config_surface/0 is :route | :flavor | nil
  #     (codex PR-5 MEDIUM-5) --------------------------------------------
  #
  # SPEC §6.1: V1 rejects `:form` (the plugin settings store is V2).
  # The merged contract validated neither here nor in `boot/1` — a
  # `%{kind: :form, ...}` compiled + booted, then crashed `/plugins`
  # with a FunctionClauseError. The gate now rejects `:form` and any
  # malformed config_surface map.
  defp check_config_surface(diagnostics, plugin_module) do
    if uses_plugin_behaviour?(plugin_module) and ensure_compiled?(plugin_module) do
      case plugin_module.config_surface() do
        nil ->
          diagnostics

        %{kind: :route, path: p, label: l} when is_binary(p) and is_binary(l) ->
          diagnostics

        %{kind: :flavor, flavor: f, label: l} when is_binary(f) and is_binary(l) ->
          diagnostics

        %{kind: :form} = surface ->
          [
            diagnostic(
              "config_surface/0 returns #{inspect(surface)} — a `:form` config " <>
                "surface is REJECTED in V1. It would auto-render settings " <>
                "persisted to a plugin-settings store that does not exist yet; " <>
                "the store is V2 (SPEC §6.1). V1 config_surface/0 is " <>
                ":route | :flavor | nil."
            )
            | diagnostics
          ]

        other ->
          [
            diagnostic(
              "config_surface/0 returns a malformed value #{inspect(other)}. V1 " <>
                "config_surface/0 is one of %{kind: :route, path: String.t(), " <>
                "label: String.t()}, %{kind: :flavor, flavor: String.t(), " <>
                "label: String.t()}, or nil (SPEC §6.1)."
            )
            | diagnostics
          ]
      end
    else
      diagnostics
    end
  rescue
    _ -> diagnostics
  end

  # --- check 7 — no direct *Registry.register / declare_table calls -----

  defp check_no_direct_registry_calls(diagnostics) do
    source_files =
      Mix.Project.config()
      |> Keyword.get(:elixirc_paths, ["lib"])
      |> Enum.flat_map(fn path -> Path.wildcard(Path.join(path, "**/*.ex")) end)
      |> Enum.reject(&Regex.match?(@mix_task_path_pattern, &1))

    offenders =
      Enum.filter(source_files, fn file ->
        case File.read(file) do
          {:ok, content} -> Regex.match?(@registry_grep_pattern, content)
          _ -> false
        end
      end)

    if offenders == [] do
      diagnostics
    else
      [
        diagnostic(
          "the following files call a *Registry.register / declare_table " <>
            "directly: #{Enum.join(offenders, ", ")}. Registration must go " <>
            "through declarations consumed by Ezagent.Plugin.boot/1 — a plugin " <>
            "author never touches a *Registry API (SPEC §3.2 grep gate)."
        )
        | diagnostics
      ]
    end
  end

  # --- check 10 — required_caps/0 callback presence + key parity --------
  #
  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §7.
  #
  # Iterate every Behavior module the plugin declares via behaviors/0.
  # Each MUST export required_caps/0; the returned map's keys ∪
  # cap_exempt_actions/0 (optional, default []) must equal actions/0.

  defp check_required_caps_callbacks(diagnostics, plugin_module) do
    if not uses_plugin_behaviour?(plugin_module) or not ensure_compiled?(plugin_module) do
      diagnostics
    else
      behavior_modules =
        plugin_module.behaviors() |> Enum.map(fn {_kind, _action, b} -> b end) |> Enum.uniq()

      Enum.reduce(behavior_modules, diagnostics, &check_behavior_required_caps/2)
    end
  rescue
    _ -> diagnostics
  end

  defp check_behavior_required_caps(behavior_module, diagnostics) do
    cond do
      not ensure_compiled?(behavior_module) ->
        diagnostics

      not function_exported?(behavior_module, :required_caps, 0) ->
        [
          diagnostic(
            "#{inspect(behavior_module)} must export required_caps/0 per SPEC " <>
              "docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §2."
          )
          | diagnostics
        ]

      true ->
        declared = behavior_module.actions()
        cap_keys = Map.keys(behavior_module.required_caps())
        exempt = Ezagent.ActionSet.cap_exempt_actions_of(behavior_module)

        if MapSet.new(declared) == MapSet.new(cap_keys ++ exempt) do
          diagnostics
        else
          [
            diagnostic(
              "#{inspect(behavior_module)} required_caps/0 keys ∪ cap_exempt_actions/0 " <>
                "must equal actions/0 exactly; declared=#{inspect(declared)} " <>
                "cap_keys=#{inspect(cap_keys)} exempt=#{inspect(exempt)}."
            )
            | diagnostics
          ]
        end
    end
  end

  # --- check 11 — required_caps/0 values are valid %Capability{} ---------

  defp check_required_caps_values_struct(diagnostics, plugin_module) do
    if not uses_plugin_behaviour?(plugin_module) or not ensure_compiled?(plugin_module) do
      diagnostics
    else
      behavior_modules =
        plugin_module.behaviors() |> Enum.map(fn {_kind, _action, b} -> b end) |> Enum.uniq()

      Enum.reduce(behavior_modules, diagnostics, &check_behavior_required_caps_struct/2)
    end
  rescue
    _ -> diagnostics
  end

  defp check_behavior_required_caps_struct(behavior_module, diagnostics) do
    cond do
      not ensure_compiled?(behavior_module) ->
        diagnostics

      not function_exported?(behavior_module, :required_caps, 0) ->
        diagnostics

      true ->
        bad =
          for {action, cap} <- behavior_module.required_caps(),
              not match?(%Ezagent.Capability{}, cap),
              do: {action, cap}

        diagnostics =
          if bad == [] do
            diagnostics
          else
            [
              diagnostic(
                "#{inspect(behavior_module)}.required_caps/0 values MUST be " <>
                  "%Ezagent.Capability{} structs (use Capability.cap/3 / cap/5). " <>
                  "Bad entries: #{inspect(bad)}"
              )
              | diagnostics
            ]
          end

        # SPEC 2026-05-27 capability-action-axis §4.2 — extended check 11:
        # verify that each entry's `action_of(cap) == action OR :any`.
        # Catches plugin authors who construct required_caps with the
        # wrong third arg (e.g. `:send` action key but `:receive` action
        # field on the cap struct). The `:any` escape hatch covers
        # orchestrator-style Behaviors that declaratively hold a
        # behavior-wildcard cap.
        action_mismatch =
          for {action, %Ezagent.Capability{} = cap} <- behavior_module.required_caps(),
              cap_action = Ezagent.Capability.action_of(cap),
              cap_action != action and cap_action != :any do
            {action, cap_action}
          end

        if action_mismatch == [] do
          diagnostics
        else
          [
            diagnostic(
              "#{inspect(behavior_module)}.required_caps/0 action-axis mismatch " <>
                "(SPEC 2026-05-27 capability-action-axis §4.2 check 11 extension). " <>
                "Each entry MUST have `Capability.action_of(cap) == map_key OR :any`. " <>
                "Mismatches (map_key → cap_action): #{inspect(action_mismatch)}"
            )
            | diagnostics
          ]
        end
    end
  end

  # --- helpers ----------------------------------------------------------

  defp ensure_compiled?(module) do
    match?({:module, ^module}, Code.ensure_compiled(module))
  end

  defp diagnostic(message) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "ezagent_plugin_check",
      file: "mix.exs",
      message: message,
      position: nil,
      severity: :error,
      details: nil
    }
  end

  defp print_diagnostic(%Mix.Task.Compiler.Diagnostic{message: message}) do
    Mix.shell().error("** (ezagent_plugin_check) " <> message)
  end
end
