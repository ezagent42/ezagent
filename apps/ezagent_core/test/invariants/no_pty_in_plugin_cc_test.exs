defmodule EzagentCore.Invariants.NoPtyInPluginCcTest do
  @moduledoc """
  Domain.Pty PR-D invariant (2026-05-21) — per SPEC §11 verification
  item 1: after the PTY migration (PRs #186 + #187 + #188 + this PR),
  the cc plugin's `lib/` MUST NOT reference any of the pre-migration
  PTY module names.

  PTY now lives entirely in `ezagent_domain_pty` (Tier-2 runtime) +
  `ezagent_domain_ui` (Tier-2 UI primitives). The cc plugin is reduced
  to genuinely CC-specific surfaces:

    * `EzagentPluginCc.Channel` — Phoenix Channel for claude TUI WS
    * `EzagentPluginCc.BridgeRegistry` — agent_uri → channel pid
    * `EzagentPluginCc.McpConfigWriter` — `.mcp.json` writer
    * `EzagentPluginCc.TokenStore` — bridge auth tokens
    * `EzagentPluginCc.Socket` — WS endpoint
    * `Ezagent.PluginCc.Template.CcAgent` — template class (consumes
      `Ezagent.Domain.Pty.start/2`)

  This grep gate fails if a future PR resurrects any of the pre-
  migration module names inside `apps/ezagent_plugin_cc/lib/`.

  Per `feedback_completion_requires_invariant_test`: PR-D's "done"
  claim is gated on this test passing AND on it failing when someone
  re-imports the legacy modules.

  ## Allowed exceptions

  Historical comments / docstring references are tolerated — they
  capture the migration rationale and refer to modules that no longer
  exist. Match-ignoring rule: any matched line that begins with `#`
  (after leading whitespace) or contains the literal `(historical)`
  is dropped from the violations list.

  ## How to fix a failing test

  1. Replace `Ezagent.PluginCc.PtyServer` calls with
     `Ezagent.Domain.Pty` facade (`start/2`, `alive?/1`, `lookup/1`,
     `stop/1`, `status/1`).
  2. Replace `EzagentPluginCc.PtyServerSupervisor` /
     `EzagentPluginCc.PtyServerRegistry` references with the facade.
  3. Replace `EzagentPluginCc.Views.PtyView` with
     `EzagentDomainUi.Pty.TerminalView`.

  Reference SPEC: `docs/superpowers/specs/2026-05-21-domain-pty-architecture.md` §11.
  """
  use ExUnit.Case, async: true

  @forbidden ~w(
    Ezagent.PluginCc.PtyServer
    EzagentPluginCc.PtyServerSupervisor
    EzagentPluginCc.PtyServerRegistry
    EzagentPluginCc.Views.PtyView
  )

  test "no pre-migration PTY module references in cc plugin lib code" do
    cc_lib = Path.join(repo_root(), "apps/ezagent_plugin_cc/lib")

    violations =
      @forbidden
      |> Enum.flat_map(fn name ->
        case System.cmd("grep", ["-rn", name, cc_lib, "--include=*.ex"], stderr_to_stdout: false) do
          {output, 0} ->
            String.split(output, "\n", trim: true)

          # grep exit 1 = no matches found → no violations for this name
          {_output, 1} ->
            []

          # grep exit ≥2 = actual error (path doesn't exist, etc.) — surface it
          {output, code} ->
            flunk("grep failed (exit #{code}) for #{name}: #{output}")
        end
      end)
      |> Enum.reject(&allowed_line?/1)

    assert violations == [],
           """
           Pre-migration PTY module references found in cc plugin lib code:

           #{Enum.join(violations, "\n")}

           PTY has moved out of plugin_cc to ezagent_domain_pty (runtime) +
           ezagent_domain_ui (UI). Update the call sites to use the facade
           `Ezagent.Domain.Pty.*` per
           docs/superpowers/specs/2026-05-21-domain-pty-architecture.md §11.
           """
  end

  # Drop lines that are clearly comments or marked as historical
  # references (migration rationale, docstring notes about the move).
  defp allowed_line?(line) do
    # Line format: "<path>:<lineno>:<content>" — strip prefix to inspect
    # actual content.
    content =
      case String.split(line, ":", parts: 3) do
        [_path, _lineno, rest] -> rest
        _ -> line
      end

    trimmed = String.trim_leading(content)

    String.starts_with?(trimmed, "#") or String.contains?(content, "(historical)")
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
