defmodule EzagentCore.Invariants.LayerPurityTest do
  @moduledoc """
  Phase 6 PR 3 invariant — three-layer model integrity.

  Layer rules:

  - `apps/ezagent_core/`         — depends on: nothing in umbrella
  - `apps/ezagent_domain_*/`     — depends on: ezagent_core + other ezagent_domain_*
  - `apps/ezagent_plugin_*/`     — depends on: ezagent_core + ezagent_domain_* + other
                                ezagent_plugin_* allowed (e.g. ezagent uses
                                cc_pty's Template Class)
  - `apps/ezagent_web*/`         — depends on: anything (endpoint + router)
  - `apps/ezagent_cli/`          — depends on: anything (CLI surface)

  This test parses each app's mix.exs `deps` list and asserts:

  1. **core has no umbrella deps** — core is the bottom of the stack.
  2. **domain apps depend only on core + other domain** — no plugin
     dep allowed (else "domain" would be impossible to use without
     pulling a specific plugin).

  Exemptions: add `# layer-violation-exempt: <reason>` on the offending
  dependency line.

  Plugins are unrestricted on purpose — composition between plugins
  (e.g. ezagent imports cc_pty's Template form fields) is fine; the
  goal is keeping the LOWER layers clean.
  """
  use ExUnit.Case, async: true

  defp apps_root do
    # cwd is the umbrella app being tested (apps/ezagent_core), so go up
    # two levels and back into apps/.
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {top, 0} ->
          top

        _ ->
          # No .git inside the release image (#21 docker) — resolve the
          # umbrella root from cwd (umbrella root or the app under test).
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end

    Path.join(String.trim(out), "apps")
  end

  test "ezagent_core has zero umbrella deps" do
    deps = read_in_umbrella_deps(:ezagent_core)

    assert deps == [],
           """
           ezagent_core must not depend on any umbrella app.
           Found: #{inspect(deps)}
           """
  end

  test "ezagent_core has no Agent-domain ownership implementation references" do
    forbidden = [
      "Ezagent.Agent.CreationInventory",
      "Ezagent.Agent.CreationInventoryEntry",
      "Ezagent.Agent.LaunchAuthority",
      "Ezagent.Agent.LaunchCoordinator",
      "Ezagent.Workspace.TaskWorkspace"
    ]

    offenders =
      :ezagent_core
      |> lib_elixir_files()
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        for module <- forbidden, String.contains?(source, module) do
          "#{Path.relative_to(path, repo_root())} #{module}"
        end
      end)

    assert offenders == []
  end

  test "ezagent_domain_* apps only depend on core + other ezagent_domain_* apps" do
    for app <- list_apps(~r/^ezagent_domain_/) do
      deps = read_in_umbrella_deps(app)

      offending =
        Enum.reject(deps, fn dep ->
          dep == :ezagent_core or
            Atom.to_string(dep) |> String.starts_with?("ezagent_domain_") or
            exempt?(app, dep)
        end)

      assert offending == [],
             """
             #{app}/mix.exs has disallowed umbrella deps: #{inspect(offending)}.

             Domain apps must only depend on ezagent_core or other ezagent_domain_* apps.
             Add `# layer-violation-exempt: <reason>` on the dep line to opt out
             (only for transient violations being repaid in a tracked PR).
             """
    end
  end

  test "ezagent_domain_* lib code does not reference EzagentPluginCc modules" do
    for app <- list_apps(~r/^ezagent_domain_/) do
      offending =
        app
        |> lib_elixir_files()
        |> Enum.flat_map(&plugin_cc_references_in_file/1)

      assert offending == [],
             """
             #{app}/lib has disallowed EzagentPluginCc module references:
             #{Enum.join(offending, "\n")}

             Domain apps must route through domain abstractions such as
             Ezagent.AgentBridge, not plugin-specific modules.
             """
    end
  end

  defp list_apps(pattern) do
    File.ls!(apps_root())
    |> Enum.filter(&File.dir?(Path.join(apps_root(), &1)))
    |> Enum.filter(&Regex.match?(pattern, &1))
    |> Enum.map(&String.to_atom/1)
  end

  defp read_in_umbrella_deps(app) do
    mix_path = Path.join([apps_root(), Atom.to_string(app), "mix.exs"])
    source = File.read!(mix_path)

    Regex.scan(~r/\{:([a-z_][a-z_0-9]*),\s*in_umbrella:\s*true\}/, source)
    |> Enum.map(fn [_match, dep] -> String.to_atom(dep) end)
  end

  defp exempt?(app, dep) do
    mix_path = Path.join([apps_root(), Atom.to_string(app), "mix.exs"])
    source = File.read!(mix_path)

    # Exemption can appear on the same line as the dep, OR on the line
    # immediately above (which is the natural form for a multi-line list).
    line_pattern = ~r/\{:#{dep},\s*in_umbrella:\s*true\}.*?layer-violation-exempt/
    above_pattern = ~r/layer-violation-exempt[^\n]*\n\s*\{:#{dep},\s*in_umbrella:\s*true\}/

    Regex.match?(line_pattern, source) or Regex.match?(above_pattern, source)
  end

  defp lib_elixir_files(app) do
    Path.join([apps_root(), Atom.to_string(app), "lib", "**", "*.ex"])
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp plugin_cc_references_in_file(path) do
    ast =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path)

    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, meta, [:EzagentPluginCc | rest]} = node, refs ->
          module = Module.concat([EzagentPluginCc | rest])
          {node, [{meta[:line] || 1, module} | refs]}

        node, refs ->
          {node, refs}
      end)

    refs
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {line, module} ->
      "#{Path.relative_to(path, repo_root())}:#{line} #{inspect(module)}"
    end)
  end

  defp repo_root do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {top, 0} ->
          top

        _ ->
          # No .git inside the release image (#21 docker) — resolve the
          # umbrella root from cwd (umbrella root or the app under test).
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end

    String.trim(out)
  end
end
