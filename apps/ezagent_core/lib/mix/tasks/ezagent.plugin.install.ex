defmodule Mix.Tasks.Ezagent.Plugin.Install do
  @shortdoc "Hot-load + start an OTP plugin app into a running Ezagent (no phx restart)"

  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (operator install).**
  > Intentionally NOT a dispatched op. Mutates the runtime BEAM's
  > code path + application supervision tree; cannot itself be
  > dispatched (it adds the Kinds that would receive dispatch).
  > Stays as `mix ezagent.*`; do NOT migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Bootstrap row) + Finding 2 carve-out.

  Phase 7 PR 36 (D7-8) — install a plugin OTP app into a running Ezagent
  without restarting `phx.server`. Closes V1.4 (dev writes plugin →
  `mix ezagent.plugin.install` → Kinds + Behaviors reachable without
  restart).

  ## Usage

      mix ezagent.plugin.install <path>           # path to a built plugin app's _build/<env>/lib/<app>/
      mix ezagent.plugin.install --app <app_name> # alternative: app already in code path, just start it

  ## What it does

  1. **Code path** — add the plugin's `ebin/` to the BEAM code path
     so modules are loadable. `:code.add_paths/1`.
  2. **Application load** — `:application.load/1` registers the app
     with the Application controller (reads `<app>.app` file).
  3. **Application ensure all started** — `:application.ensure_all_started/1`
     boots the plugin's supervision tree, which runs its
     `Application.start/2` callback. The plugin's existing
     registration hooks (`BehaviorRegistry.register/3`,
     `KindRegistry` via spawn, `TemplateRegistry.register/1`,
     `RoutingRegistry.declare_table/2`) fire there.
  4. **Status echo** — print the newly-registered Kinds + Behaviors
     so the operator sees what landed.

  ## What it does NOT do (deferred per D7-8)

  - **Plugin unload / swap** — requires Kind lifecycle management
    for live instances of the unregistered Kind; non-trivial,
    deferred to dev-team's call later.
  - **Production OTP hot-deploy** (`relup`) — different problem
    domain; out of Phase 7 scope.

  ## Concurrency

  Two concurrent `mix ezagent.plugin.install` invocations on the same
  Ezagent instance race against the Application controller, which
  serializes load/start internally. The second invocation of the
  same app silently observes `{:error, {:already_loaded, _}}` and
  treats it as success. Two installs of DIFFERENT apps that happen
  to register the same `template_name` or Kind URI scheme will
  surface `{:error, :duplicate}` from the registry (per
  `TemplateRegistry` strict-duplicate semantics) — the second
  install fails clean with a clear error.

  ## Mix.env() pitfall (must read for plugin authors)

  A plugin's `Application.start/2` callback may use compile-time
  `Mix.env()` to switch behavior (e.g. `if Mix.env() != :test, do:
  seed_initial_data/0`). At hot-install time, `Mix.env()` returns
  the value the plugin was **built** with, NOT the host's runtime
  env. If the plugin was compiled with `MIX_ENV=prod`, a hot-install
  into a `:dev` Ezagent runs the prod-branch boot logic — usually
  surprising.

  **Recommendation**: plugin authors should prefer
  `System.get_env("MIX_ENV")` for env-dependent boot logic (or skip
  env-dependent boot entirely; let the operator drive seeds via
  explicit mix tasks). This is documented in the plugin authoring
  guide (Phase 7-4 PR 51 deliverable).

  ## Reverse: there is no `mix ezagent.plugin.uninstall` (intentionally)

  D7-8: removing a plugin requires gracefully stopping all live
  Kind instances of the unregistered Kind, deregistering the
  Behaviors, cleaning the routing tables, etc. The interactions are
  numerous and the failure modes are subtle (a Kind in mid-dispatch
  during unload). Deferred to dev-team to decide if and how they
  want this. Restart phx in the meantime.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, paths, _} =
      OptionParser.parse(argv, switches: [app: :string, ebin: :string])

    case {opts[:app], paths} do
      {nil, []} ->
        Mix.shell().error("usage: mix ezagent.plugin.install <path-to-plugin> | --app <app_name>")
        exit({:shutdown, 2})

      {nil, [path | _]} ->
        install_from_path(path, opts)

      {app_name, _} ->
        install_by_app_name(String.to_atom(app_name))
    end
  end

  defp install_from_path(path, opts) do
    abs = Path.expand(path)

    unless File.dir?(abs) do
      Mix.shell().error("plugin path not found or not a directory: #{abs}")
      exit({:shutdown, 1})
    end

    # Plugin-package (Q1-C): if the path is a plugin PACKAGE (has a
    # manifest.json), delegate to the full hot-load orchestrator — it
    # does code-load + app-start (this task's existing path) AND seeds
    # the package's seed-definitions + registers its assets. The legacy
    # raw-ebin path below still serves a plain compiled app dir without
    # a manifest.
    if File.exists?(Path.join(abs, "manifest.json")) do
      # Operator mix-task supplies the EZAGENT_HOME plugins dir as the
      # zip-unpack target (the runtime Ezagent.PluginPackage module does
      # NOT call Home.path/1 directly — sanctioned home-path resolution
      # lives in operator tooling, not runtime lib code).
      case Ezagent.PluginPackage.install(abs, unpack_to: Ezagent.Home.path(:plugins)) do
        {:ok, %{slug: slug, app: app}} ->
          Mix.shell().info(
            "✓ plugin package #{inspect(slug)} (app #{inspect(app)}) installed + hot-loaded"
          )

        {:error, reason} ->
          Mix.shell().error("plugin package install failed: #{inspect(reason)}")
          exit({:shutdown, 1})
      end

      exit({:shutdown, 0})
    end

    ebin = opts[:ebin] || Path.join(abs, "ebin")

    unless File.dir?(ebin) do
      Mix.shell().error(
        "expected ebin/ at #{ebin} — plugin must be compiled first " <>
          "(`cd #{abs} && mix compile`); or pass --ebin <path>"
      )

      exit({:shutdown, 1})
    end

    :ok = :code.add_path(String.to_charlist(ebin)) |> ensure_path_added!()

    # Derive app name from the .app file in ebin
    case Path.wildcard(Path.join(ebin, "*.app")) do
      [] ->
        Mix.shell().error("no .app file found in #{ebin} — is this a valid OTP app build?")
        exit({:shutdown, 1})

      [app_file | _] ->
        app_name =
          app_file
          |> Path.basename(".app")
          |> String.to_atom()

        Mix.shell().info(
          "Resolved app name from #{Path.basename(app_file)}: #{inspect(app_name)}"
        )

        install_by_app_name(app_name)
    end
  end

  defp ensure_path_added!(true), do: :ok

  defp ensure_path_added!({:error, reason}) do
    Mix.shell().error("failed to add plugin ebin to code path: #{inspect(reason)}")
    exit({:shutdown, 1})
  end

  defp install_by_app_name(app_name) when is_atom(app_name) do
    Mix.shell().info("Loading application #{inspect(app_name)} ...")

    load_result =
      case :application.load(app_name) do
        :ok -> :ok
        {:error, {:already_loaded, ^app_name}} -> :ok
        {:error, reason} -> {:error, reason}
      end

    case load_result do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error("application.load failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    Mix.shell().info("Starting application #{inspect(app_name)} (and dependencies) ...")

    case :application.ensure_all_started(app_name) do
      {:ok, started} ->
        echo_started(app_name, started)
        echo_registrations(app_name)

      {:error, reason} ->
        Mix.shell().error("ensure_all_started failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp echo_started(target, started) do
    if started == [] do
      Mix.shell().info("✓ #{inspect(target)} was already running.")
    else
      Mix.shell().info("✓ Started: #{started |> Enum.map(&inspect/1) |> Enum.join(", ")}")
    end
  end

  defp echo_registrations(app_name) do
    # Best-effort observability: enumerate registry entries that
    # mention the plugin's module namespace. Plugin authors typically
    # use `EzagentPlugin<Name>` or similar, so we look for substring
    # matches in module atoms.

    needle = app_name |> Atom.to_string()
    needle_camel = camelize(needle)

    behaviors = list_behaviors_matching(needle_camel)
    templates = list_templates_matching(needle_camel)

    if behaviors == [] and templates == [] do
      Mix.shell().info(
        "(no Behavior or Template Class registrations contained " <>
          "#{inspect(needle_camel)} — plugin may register lazily or use a " <>
          "different naming convention)"
      )
    else
      if behaviors != [] do
        Mix.shell().info("Registered Behaviors:")
        Enum.each(behaviors, fn b -> Mix.shell().info("  • #{inspect(b)}") end)
      end

      if templates != [] do
        Mix.shell().info("Registered Template Classes:")
        Enum.each(templates, fn t -> Mix.shell().info("  • #{inspect(t)}") end)
      end
    end
  end

  defp camelize(snake) when is_binary(snake) do
    snake
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join("")
  end

  defp list_behaviors_matching(needle) do
    try do
      Ezagent.BehaviorRegistry.list_all()
      |> Enum.map(fn {_key, behavior_mod} -> behavior_mod end)
      |> Enum.uniq()
      |> Enum.filter(fn m -> m |> Atom.to_string() |> String.contains?(needle) end)
    rescue
      _ -> []
    end
  end

  defp list_templates_matching(needle) do
    try do
      # TemplateRegistry's public surface is `registered_template_names/0`
      # which returns ETS objects as `[{name, class_mod}, ...]`.
      Ezagent.TemplateRegistry.registered_template_names()
      |> Enum.filter(fn
        {_name, class_mod} when is_atom(class_mod) ->
          class_mod |> Atom.to_string() |> String.contains?(needle)

        _ ->
          false
      end)
      |> Enum.map(fn {name, _} -> name end)
    rescue
      _ -> []
    end
  end
end
