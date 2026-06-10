defmodule EzagentCore.Invariants.AllPluginAppsWiredToWebTest do
  @moduledoc """
  Invariant: every `apps/ezagent_plugin_*` directory MUST be listed in
  `apps/ezagent_web/mix.exs` deps as `{:ezagent_plugin_<name>, in_umbrella: true}`.

  Why this matters: a plugin's OTP `Application.start/2` is what calls
  `Ezagent.Plugin.boot/1`, registering flavors / template classes /
  behaviors / caps. If the web release doesn't depend on the plugin,
  `Application.start` never runs at boot, the plugin is silently dead
  weight — `:no_kind_module_for_agent` from any code path expecting
  the plugin's Kind to exist.

  Lesson (2026-05-25): PR #258 created `ezagent_plugin_np` but never
  added it to `apps/ezagent_web/mix.exs` deps. The plugin compiled
  + ran its own tests against `EzagentPluginNp.Application` directly,
  so unit tests passed. But the long-running web server never started
  the OTP app → np-flavor agents couldn't be invited (per Allen
  2026-05-25). One-line fix; this test locks it in for future plugins.

  Exemption: add `# plugin-wire-exempt: <reason>` on the matching
  `apps/ezagent_plugin_*` directory's mix.exs `@app` declaration or
  alongside the apps/ entry. (Rare — only a non-OTP plugin or
  experimental scratch dir would qualify.)
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

  test "every apps/ezagent_plugin_* is listed in ezagent_web/mix.exs deps" do
    plugin_apps =
      apps_root()
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(apps_root(), &1)))
      |> Enum.filter(&String.starts_with?(&1, "ezagent_plugin_"))
      |> Enum.sort()

    web_mix_path = Path.join([apps_root(), "ezagent_web", "mix.exs"])
    web_mix_source = File.read!(web_mix_path)

    web_in_umbrella_deps =
      Regex.scan(~r/\{:([a-z_][a-z_0-9]*),\s*in_umbrella:\s*true\}/, web_mix_source)
      |> Enum.map(fn [_match, dep] -> dep end)
      |> MapSet.new()

    missing =
      plugin_apps
      |> Enum.reject(fn app -> MapSet.member?(web_in_umbrella_deps, app) end)
      |> Enum.reject(&plugin_wire_exempt?/1)

    assert missing == [],
           """
           These plugin apps exist under apps/ but are NOT wired into
           apps/ezagent_web/mix.exs deps:

               #{Enum.map_join(missing, "\n    ", & &1)}

           Without `{:<app>, in_umbrella: true}` in ezagent_web's deps,
           the plugin's `Application.start/2` never runs at web boot —
           its `Ezagent.Plugin.boot/1` never fires, its flavors /
           template classes / behaviors / caps never register, and any
           code path expecting the plugin's Kind to exist returns
           `:no_kind_module_for_agent` (or similar) at runtime.

           Fix: add the missing entry to the `defp deps` block in
           apps/ezagent_web/mix.exs, alongside the other
           ezagent_plugin_* deps.

           If the plugin is intentionally NOT wired (rare — only a
           non-OTP plugin or experimental scratch dir would qualify),
           add `# plugin-wire-exempt: <reason>` to the plugin's mix.exs
           @app declaration.
           """
  end

  defp plugin_wire_exempt?(app) do
    mix_path = Path.join([apps_root(), app, "mix.exs"])

    case File.read(mix_path) do
      {:ok, source} -> source =~ ~r/plugin-wire-exempt/
      {:error, _} -> false
    end
  end
end
