defmodule Ezagent.Invariants.TemplateClassExtensionContractTest do
  @moduledoc """
  Invariant gate (codex PR2 round-1 MEDIUM-3) — a Template Class that
  implements ANY of the extension-management callbacks
  (`list_extensions/1`, `toggle_extension/3`, `destroy_config_dir/2`)
  MUST implement ALL of them.

  Partial opt-in leaks filesystem on destroy (a Class that knows how to
  CREATE config dirs but cannot DESTROY them is a leak vector), exposes
  inconsistent LV state (toggle without list = no preview; list without
  toggle = read-only UI), and violates the plugin-isolation contract.

  This test enumerates every `Ezagent.Kind.Template` implementation in
  the umbrella and asserts the all-or-nothing rule. A future plugin
  author who adds just one of the three callbacks gets a clear error
  pointing at the missing pieces.

  Allen 2026-05-24 / Codex PR2 round-1.
  """

  use ExUnit.Case, async: true

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  @extension_callbacks [
    {:list_extensions, 1},
    {:toggle_extension, 3},
    {:destroy_config_dir, 2}
  ]

  # Codex PR2 round-2 MEDIUM-1 → round-3 MEDIUM-1:
  # - Round-2: running from `apps/ezagent_core` only saw ezagent_core's
  #   loaded apps; plugin apps weren't enumerable. Fix: explicitly load
  #   a hardcoded list of umbrella apps.
  # - Round-3: the hardcoded list went stale (missed
  #   ezagent_plugin_feishu, ezagent_plugin_liveview + any future
  #   plugin), so a partial opt-in in a missed app would silently
  #   ship. Fix: discover the umbrella apps from `apps/*` on disk so
  #   new plugins are automatically covered.
  #
  # The discovery walks the umbrella's `apps/` dir relative to the
  # repository root. Works whether mix test runs from the umbrella
  # root or from a single app's dir.

  test "every Template Class implements all-or-none of the extension callbacks" do
    classes = template_class_modules()

    # We must see SOME classes — otherwise the test is silently
    # vacuous. cc / echo / curl / np all ship Template Classes; if
    # we see zero, the umbrella-load failed.
    refute classes == [],
           "no Template Classes found — umbrella app loading is broken; " <>
             "this test cannot prove anything"

    violations =
      Enum.flat_map(classes, fn mod ->
        Code.ensure_loaded(mod)

        implemented =
          Enum.filter(@extension_callbacks, fn {name, arity} ->
            function_exported?(mod, name, arity)
          end)

        cond do
          # All-none = OK (the class opts out entirely)
          implemented == [] ->
            []

          # All-all = OK (the class opts in entirely)
          length(implemented) == length(@extension_callbacks) ->
            []

          # Partial = violation
          true ->
            missing = @extension_callbacks -- implemented
            [{mod, implemented, missing}]
        end
      end)

    assert violations == [],
           """
           Template Classes with PARTIAL extension-callback opt-in:

           #{format_violations(violations)}

           A Class that wants per-agent extensions MUST implement all 3:
             list_extensions/1, toggle_extension/3, destroy_config_dir/2.

           Otherwise destroy leaks filesystem (no cleanup) or the LV is
           internally inconsistent (toggle without list, list without
           toggle). Codex PR2 round-1 MEDIUM-3.
           """
  end

  defp template_class_modules do
    apps = discover_umbrella_apps()

    # Force-load each app so its module list is visible to
    # `:application.get_key/2`. Codex PR2 round-3 MEDIUM-1: the app
    # list is now DISCOVERED from `apps/` on disk, not hardcoded,
    # so new plugin apps are automatically covered.
    for app <- apps do
      _ = Application.load(app)
    end

    for app <- apps,
        {:ok, modules} <- [:application.get_key(app, :modules)],
        mod <- modules,
        implements_kind_template?(mod) do
      mod
    end
  end

  # Walk up from the test file's location to find the umbrella's
  # `apps/` dir, return each subdir name as an atom. Works regardless
  # of which directory `mix test` was invoked from.
  defp discover_umbrella_apps do
    apps_dir = umbrella_apps_dir()

    case File.ls(apps_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          File.dir?(Path.join(apps_dir, name)) and
            File.exists?(Path.join([apps_dir, name, "mix.exs"]))
        end)
        |> Enum.map(&String.to_atom/1)

      _ ->
        []
    end
  end

  defp umbrella_apps_dir do
    # __DIR__ is the test file's dir
    # apps/ezagent_core/test/invariants → ../../../ to umbrella root
    # → apps/
    Path.expand("../../../../", __DIR__)
    |> Path.join("apps")
  end

  defp implements_kind_template?(mod) do
    Code.ensure_loaded(mod)
    behaviours = mod.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    Ezagent.Kind.Template in behaviours
  rescue
    _ -> false
  end

  defp format_violations(violations) do
    violations
    |> Enum.map(fn {mod, implemented, missing} ->
      "  - #{inspect(mod)}\n" <>
        "      implemented: #{format_callbacks(implemented)}\n" <>
        "      missing:     #{format_callbacks(missing)}"
    end)
    |> Enum.join("\n")
  end

  defp format_callbacks(cbs) do
    cbs
    |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
    |> Enum.join(", ")
  end
end
