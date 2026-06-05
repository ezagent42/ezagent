defmodule EzagentCore.Invariants.NoV1BridgeAfterCutoverTest do
  @moduledoc """
  Decision #144 cross-PR gate (Phase 7 PR 32c, rebrand-4): after the
  v1 CC bridge prototype is deleted, no production source file may
  reference `Ezagent.Bridge.V1Prototype` or
  `ezagent_plugin_cc_bridge_v1_prototype`.

  A reintroduction would silently resurrect the parallel-bridge
  ambiguity (two transports, two registry tables, two reply paths)
  the cutover was designed to retire.

  ## Scope

  Scans every tracked `.ex` / `.exs` / `mix.exs` under `apps/`,
  excluding:

  - This test file itself (it must mention the name to assert it).
  - Markdown / docs / phase-specs / forensic notes — those are
    historical record and intentionally retain v1 references.

  Failure mode: prints offending file + line so the gating PR can
  be reverted before merge.
  """
  use ExUnit.Case, async: true

  @forbidden_module ~c"Ezagent.Bridge.V1Prototype"
  @forbidden_app ~c"ezagent_plugin_cc_bridge_v1_prototype"

  defp apps_root do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
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

  test "no production source under apps/ references Ezagent.Bridge.V1Prototype" do
    self_path = Path.relative_to(__ENV__.file, apps_root())

    offenders =
      apps_root()
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.reject(fn p ->
        # Allow this test itself.
        # Allow ezagent_plugin_cc_bridge_v1_prototype/ if it ever
        # re-appears — the test below catches the dep + dir resurrection.
        String.ends_with?(p, self_path) or
          String.contains?(p, "/ezagent_plugin_cc_bridge_v1_prototype/")
      end)
      |> Enum.flat_map(fn p ->
        case File.read(p) do
          {:ok, body} ->
            if String.contains?(body, to_string(@forbidden_module)) do
              [{p, find_first_line(body, to_string(@forbidden_module))}]
            else
              []
            end

          _ ->
            []
        end
      end)

    assert offenders == [],
           """
           v1 bridge resurrected — these files reference
           Ezagent.Bridge.V1Prototype:

           #{Enum.map_join(offenders, "\n", fn {p, line} -> "  #{p}:#{line}" end)}

           Decision #144: after Phase 7 PR 32c the v1 prototype is
           deleted; no production code may name it. If you need
           bridge surface, use EzagentPluginCc.{Channel,
           BridgeRegistry, McpConfigWriter, TokenStore}.
           """
  end

  test "no umbrella app declares :ezagent_plugin_cc_bridge_v1_prototype as a dep" do
    offenders =
      apps_root()
      |> Path.join("*/mix.exs")
      |> Path.wildcard()
      |> Enum.flat_map(fn p ->
        body = File.read!(p)

        if String.contains?(body, to_string(@forbidden_app)) do
          [p]
        else
          []
        end
      end)

    assert offenders == [],
           """
           v1 plugin dep resurrected — these mix.exs declare
           :ezagent_plugin_cc_bridge_v1_prototype:

           #{Enum.join(offenders, "\n  ")}

           Decision #144: the v1 prototype app is deleted; nothing
           should depend on it.
           """
  end

  test "the v1 plugin directory does not exist" do
    v1_dir = Path.join(apps_root(), "ezagent_plugin_cc_bridge_v1_prototype")

    refute File.dir?(v1_dir),
           """
           v1 plugin directory resurrected at #{v1_dir}.

           Decision #144: PR 32c deleted apps/ezagent_plugin_cc_bridge_v1_prototype/
           and the production CC bridge is now EzagentPluginCc
           (Phoenix.Channel over WebSocket). Re-introducing the v1
           prototype reverts the cutover.
           """
  end

  defp find_first_line(body, needle) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value("?", fn {line, idx} ->
      if String.contains?(line, needle), do: idx, else: nil
    end)
  end
end
