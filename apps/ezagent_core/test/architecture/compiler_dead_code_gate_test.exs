Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.CompilerDeadCodeGateTest do
  use ExUnit.Case, async: false

  import EzagentCore.ArchitectureCase, only: []

  @moduledoc """
  FF-3 (cleanup-4) — the compiler dead-code gate.

  The cleanup audit proved that grep / static line-scanning is an UNSOUND
  detector of dead code: for unused private functions and unreachable /
  mis-grouped function clauses it is ~100% false-positive (a private fn
  referenced only via `&mod.fun/arity`, a metaprogramming call, or a
  same-name clause split by a helper all defeat a textual scan). The ONLY
  reliable detector for this class is the Elixir COMPILER itself, which
  emits:

    * "function _/_ is unused" for a genuinely-unreferenced `defp`,
    * "this clause cannot match" / "clauses ... should be grouped together"
      for unreachable / mis-grouped clauses,
    * "function _/_ required by behaviour ... is not implemented" for a
      stale Behavior fixture.

  This test enforces `mix compile --warnings-as-errors` as a hard gate so a
  NEWLY-introduced unused private function or unreachable clause fails CI
  by construction — we do not chase the rest of the dead-code campaign with
  more (unsound) static scanners, we let the compiler carry it.

  Wiring: the same gate runs in the root `precommit` alias
  (`mix.exs` → `compile --warnings-as-errors --force`). This test is the
  ExUnit-discoverable companion so the gate is exercised by the normal
  `mix test` run, not only by precommit. It runs the IDENTICAL command
  (`--warnings-as-errors --force`) — an incremental compile would skip
  already-compiled modules and could let a warning in an untouched module
  evade a test-only CI path, so the in-suite check uses `--force` too.

  Allowlist policy: there is NO allowlist. A warning is either fixed at the
  root cause (group the clauses / delete the dead fn / implement the
  callback) or — only if genuinely unfixable and justified — suppressed at
  the single offending site with a documented `@compile` / inline rationale.
  A blanket project-wide suppression flag is forbidden (it would dissolve
  the gate). If this test ever needs a carve-out, the carve-out belongs in
  THIS file with a written justification, reviewed like any other gate.
  """

  @doc false
  # Run from the umbrella root so the alias / paths resolve identically to
  # the precommit gate.
  defp umbrella_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
      {top, 0} -> String.trim(top)
      _ -> Path.expand("../../../../..", __DIR__)
    end
  end

  @tag :compiler_gate
  @tag timeout: 300_000
  test "umbrella compiles with --warnings-as-errors --force (FF-3 dead-code gate)" do
    # --force matches the hard precommit gate EXACTLY (codex
    # adversarial-review MEDIUM): an incremental compile silently skips
    # already-compiled modules, so a warning in an untouched module could
    # evade a CI path that only runs `mix test`. --force recompiles the
    # full tree so this in-suite check is as sound as the precommit alias —
    # the two are intentionally identical (`compile --warnings-as-errors
    # --force`); keep them in sync.
    {output, status} =
      System.cmd(
        "mix",
        ["compile", "--warnings-as-errors", "--force", "--all-warnings"],
        cd: umbrella_root(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, """
    FF-3 compiler dead-code gate FAILED: `mix compile --warnings-as-errors`
    emitted warnings. The compiler is the sound detector for unused private
    functions + unreachable/mis-grouped clauses — fix the root cause (group
    the clauses, delete the dead fn, or implement the missing callback). Do
    NOT add a blanket suppression flag.

    Compiler output:
    #{output}
    """
  end
end
