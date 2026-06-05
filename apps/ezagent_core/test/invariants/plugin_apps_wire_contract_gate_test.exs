defmodule EzagentCore.Invariants.PluginAppsWireContractGateTest do
  @moduledoc """
  Umbrella invariant — every `apps/ezagent_plugin_*` app MUST wire
  BOTH halves of the `Ezagent.Plugin` contract gate (plugin authoring
  contract SPEC §3.2 / codex PR-5 HIGH-3):

  1. the `:ezagent_plugin_check` Mix compiler in `project/0`
     `compilers:`, AND
  2. the `:ezagent_plugin` env key in `application/0` `env:`.

  Why both, and why an invariant test:

  The `:ezagent_plugin_check` compiler is the *non-bypassable* app-level
  gate. codex PR-5 HIGH-3 showed it WAS bypassable: a plugin app could
  add the compiler but omit `env: [ezagent_plugin: ...]`, and the
  compiler (a no-op when un-keyed) skipped every check. HIGH-3 fixed
  the compiler so an `ezagent_plugin_*` app with no key now FAILS the
  build. This test is the complementary guard: it fails CI the instant
  a NEW plugin app (or a regressed existing one) is missing EITHER
  half — catching the misconfiguration at the umbrella level even
  before that app is compiled.

  Per `feedback_completion_requires_invariant_test`: the contract's
  "the gate is non-bypassable" promise is only true if every plugin
  app is actually wired to it. This test is that promise made into a
  failing-when-violated check.
  """

  use ExUnit.Case, async: true

  defp apps_root do
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

  defp plugin_apps do
    File.ls!(apps_root())
    |> Enum.filter(&File.dir?(Path.join(apps_root(), &1)))
    |> Enum.filter(&String.starts_with?(&1, "ezagent_plugin_"))
    |> Enum.sort()
  end

  test "there is at least one ezagent_plugin_* app to check" do
    # Guards against a silently-passing test if the glob ever breaks.
    assert plugin_apps() != [],
           "expected apps/ezagent_plugin_* apps to exist — the invariant has nothing to check"
  end

  test "every ezagent_plugin_* app wires the :ezagent_plugin_check compiler" do
    for app <- plugin_apps() do
      source = File.read!(Path.join([apps_root(), app, "mix.exs"]))

      assert source =~ ":ezagent_plugin_check",
             """
             #{app}/mix.exs does NOT wire the :ezagent_plugin_check compiler.

             Every plugin app must add it to project/0 compilers:, e.g.
                 compilers: Mix.compilers() ++ [:ezagent_plugin_check]
             Without it the non-bypassable contract gate never runs for #{app}
             (plugin authoring contract SPEC §3.2 / codex PR-5 HIGH-3).
             """
    end
  end

  test "every ezagent_plugin_* app declares the :ezagent_plugin env key" do
    for app <- plugin_apps() do
      source = File.read!(Path.join([apps_root(), app, "mix.exs"]))

      # The key is set inside application/0's `env:` keyword list —
      # `env: [ezagent_plugin: <Module>]`.
      assert source =~ ~r/ezagent_plugin:\s*[A-Z][A-Za-z0-9_.]*/,
             """
             #{app}/mix.exs does NOT declare the :ezagent_plugin env key.

             Every plugin app must name its Ezagent.Plugin contract module in
             application/0, e.g.
                 def application do
                   [..., env: [ezagent_plugin: #{Macro.camelize(app)}]]
                 end
             Without it the :ezagent_plugin_check gate FAILS the build for #{app}
             (codex PR-5 HIGH-3) — and this invariant catches the omission first.
             """
    end
  end
end
