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

  ## Behavior for an un-migrated app — DESIGN CHOICE: no-op pass

  PR-1 only DEFINES this compiler. It is added to a plugin app's
  `mix.exs` only in the PR that migrates that app (PR-2/3). To make
  that wiring safe to land *before* the rest of a migration, this
  compiler is a **no-op `{:ok, []}`** for any app that has no
  `:ezagent_plugin` app-env key. Rationale: the `compilers:` line and
  the plugin module + `:ezagent_plugin` key may land in separate
  commits; a no-op-when-unconfigured compiler never blocks a partial
  migration, while still being a hard gate the instant the
  `:ezagent_plugin` key appears. (`ezagent_core` itself never sets the
  key, so adding the compiler nowhere-near a plugin is harmless too.)

  ## Checks (SPEC §3.2) — run only once `:ezagent_plugin` is set

  1. The app declares a plugin module (the `:ezagent_plugin` key).
  2. That module `use`s `Ezagent.Plugin` (`@behaviour Ezagent.Plugin`
     present).
  3. Every declared kind / behavior / template / agent-flavor module
     exists and implements its own behaviour (`Ezagent.Kind` /
     `Ezagent.Behavior` / `Ezagent.Kind.Template`).
  4. Every `spawns/0` scheme is one of the six core schemes
     (`Ezagent.Plugin.core_schemes/0`) — codex HIGH-4.
  5. The app source does not call `*Registry.register` /
     `RoutingRegistry.declare_table` directly — registration goes
     through `Ezagent.Plugin.boot/1` (grep gate).

  Any failure → the compiler returns `{:error, [diagnostic]}`, which
  fails the build with a precise diagnostic.
  """

  @registry_grep_pattern ~r/\b(?:Ezagent\.)?(?:Behavior|Spawn|Template|Plugin|AgentFlavor|Routing)Registry\.(?:register|declare_table)\b/

  @impl Mix.Task.Compiler
  def run(_argv) do
    plugin_module = configured_plugin_module()

    if is_nil(plugin_module) do
      # Un-migrated app (no `:ezagent_plugin` key) — no-op pass. See
      # moduledoc "DESIGN CHOICE".
      {:ok, []}
    else
      diagnostics =
        []
        |> check_uses_behaviour(plugin_module)
        |> check_declared_modules(plugin_module)
        |> check_spawn_schemes(plugin_module)
        |> check_no_direct_registry_calls()

      if diagnostics == [] do
        {:ok, []}
      else
        Enum.each(diagnostics, &print_diagnostic/1)
        {:error, diagnostics}
      end
    end
  end

  # --- which plugin module does this app declare? -----------------------

  # Read the `:ezagent_plugin` app-env key set by the plugin app's
  # `mix.exs` `application/0` `env:`. Prefer the loaded application
  # environment (`Application.get_env/3` — the `.app` file's `env`
  # populates this); fall back to the in-memory `Mix.Project` config
  # (the application may not be loaded yet on a fresh build).
  defp configured_plugin_module do
    app = Keyword.fetch!(Mix.Project.config(), :app)

    Application.get_env(app, :ezagent_plugin) || from_mix_project()
  end

  defp from_mix_project do
    Mix.Project.config()
    |> Keyword.get(:application, [])
    |> Keyword.get(:env, [])
    |> Keyword.get(:ezagent_plugin)
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
        Ezagent.Behavior,
        "behaviors/0"
      )
      |> check_modules(plugin_module.template_classes(), Ezagent.Kind.Template, "template_classes/0")
      |> check_modules(
        Enum.flat_map(plugin_module.agent_flavors(), fn d -> [d.kind, d.template_class] end),
        nil,
        "agent_flavors/0"
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

  # `expected_behaviour` may be nil (agent-flavor modules are checked
  # for existence; their kind / template_class behaviours are checked
  # by the kinds/0 + template_classes/0 passes if also declared there).
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

        not is_nil(expected_behaviour) and
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

    behaviour in behaviours
  end

  # --- check 4 — every spawns/0 scheme is core --------------------------

  defp check_spawn_schemes(diagnostics, plugin_module) do
    if uses_plugin_behaviour?(plugin_module) and ensure_compiled?(plugin_module) do
      core = Ezagent.Plugin.core_schemes()

      Enum.reduce(plugin_module.spawns(), diagnostics, fn {scheme, _fun}, acc ->
        if scheme in core do
          acc
        else
          [
            diagnostic(
              "spawns/0 declares scheme #{inspect(scheme)}, which is not one of " <>
                "the six core schemes (#{Enum.join(core, ", ")}). Plugins do NOT " <>
                "own top-level URI schemes (SPEC §5.8 — the feishu:// deletion)."
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

  # --- check 5 — no direct *Registry.register / declare_table calls -----

  defp check_no_direct_registry_calls(diagnostics) do
    source_files =
      Mix.Project.config()
      |> Keyword.get(:elixirc_paths, ["lib"])
      |> Enum.flat_map(fn path -> Path.wildcard(Path.join(path, "**/*.ex")) end)

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
