defmodule EzagentCore.Invariants.NoBehaviorModuleReferenceTest do
  @moduledoc """
  Elimination gate for the `Ezagent.Behavior` → `Ezagent.ActionSet` rename
  (SPEC `docs/together/2026-07-02/specs/T1-preprod-foundation.md`, project A).

  `Ezagent.Behavior` was renamed to `Ezagent.ActionSet` because the module is a
  *set of action handlers* for a domain (it declares `actions/0` + a
  `handle_<action>` per action), not a single behaviour — and it collided with
  Elixir's built-in `@behaviour`. This is the failing-when-violated invariant
  (per `feedback_completion_requires_invariant_test`): any future PR that
  re-introduces a reference to the retired module name fails here.

  ## What is forbidden

  1. `Ezagent.Behavior` followed by a word boundary — covers the base module,
     every child (`Ezagent.Behavior.Chat`), `use`/`@behaviour Ezagent.Behavior`,
     and the `"Elixir.Ezagent.Behavior."` dynamic-module string.
  2. The `Module.concat([:Ezagent, :Behavior, ...])` atom-list form.
  3. The grouped-alias form `Ezagent.{... Behavior ...}` — this DOES NOT contain
     the literal substring `Ezagent.Behavior`, so it must be matched separately
     (it was the one escape hatch the mechanical rename's `\\b` pattern missed).

  Note `Ezagent.BehaviorRegistry` / `Ezagent.World.Behavior.*` are intentionally
  OUT of scope — the SPEC renames `Ezagent.Behavior.*` only. Both survive the
  `\\bBehavior\\b`-anchored patterns above (Registry has no word boundary after
  `Behavior`; `World.Behavior` is a different namespace not prefixed
  `Ezagent.Behavior`).

  ## Scope

  Hard-zero across the compiled source tree: `apps/*/lib` + ALL of `apps/*/test`
  (not just `test/support`) + the umbrella-root `test/`, plus living `docs/`.

  ## Docs allowlist (frozen historical design records)

  The old name legitimately survives in DATED / historical design docs that
  describe the pre-rename state or the rename itself — rewriting them would
  falsify a frozen record. Those trees are allowlisted by path prefix
  (`@historical_doc_prefixes`). Living reference docs (docs root, `architecture/`,
  `onboarding/`, `runbook/`, `futures/`) were rewritten to `Ezagent.ActionSet`
  and ARE scanned, so a regression in a living doc — or a fresh doc outside the
  frozen trees — fires here.
  """

  use ExUnit.Case, async: true

  @forbidden [
    {~r/Ezagent\.Behavior\b/, "Ezagent.Behavior<word-boundary> (module ref / string)"},
    {~r/:Ezagent,\s*:Behavior\b/, "Module.concat([:Ezagent, :Behavior, ...]) atom form"},
    {~r/Ezagent\.\{[^}]*\bBehavior\b/, "grouped alias Ezagent.{... Behavior ...}"}
  ]

  # This gate file necessarily NAMES the retired module in its docstring/regexes.
  @self_path "apps/ezagent_core/test/invariants/no_behavior_module_reference_test.exs"

  # Frozen / dated design-doc trees — the old name is a historical-record mention.
  @historical_doc_prefixes [
    "docs/together/",
    "docs/superpowers/",
    "docs/phase-specs/",
    "docs/notes/",
    "docs/scenarios/",
    "docs/e2e/"
  ]

  @source_globs [
    "apps/*/lib/**/*.ex",
    "apps/*/lib/**/*.exs",
    "apps/*/test/**/*.ex",
    "apps/*/test/**/*.exs",
    "test/**/*.ex",
    "test/**/*.exs",
    # Runtime seed scripts (loaded by E2E harnesses — real code, not built into
    # the app tree, so easy to miss; a stale ActionSet name here surfaces only
    # at E2E run time as `{:invalid_socialware_behavior, Ezagent.Behavior.*}`).
    "scripts/**/*.ex",
    "scripts/**/*.exs",
    "scripts/**/*.sh"
  ]

  @doc_globs [
    # Root living reference docs (ARCHITECTURE / GLOSSARY / IMPLEMENTATION_ROADMAP
    # / CLAUDE) — kept current, scanned.
    "*.md",
    "docs/**/*.md",
    "docs/**/*.html"
  ]

  test "no source or living doc references the retired Ezagent.Behavior module" do
    root = repo_root()

    offenders =
      scanned_files(root)
      |> Enum.flat_map(fn rel ->
        text = File.read!(Path.join(root, rel))

        for {re, label} <- @forbidden, Regex.match?(re, text), do: "#{rel}  [#{label}]"
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert offenders == [],
           "Ezagent.Behavior → Ezagent.ActionSet rename leak — these files still " <>
             "reference the retired module name:\n" <>
             Enum.join(offenders, "\n") <>
             "\n\nRename to Ezagent.ActionSet. (Ezagent.BehaviorRegistry and " <>
             "Ezagent.World.Behavior.* are out of scope and are not matched.)"
  end

  defp scanned_files(root) do
    source = wildcard(root, @source_globs)

    docs =
      root
      |> wildcard(@doc_globs)
      |> Enum.reject(fn rel ->
        Enum.any?(@historical_doc_prefixes, &String.starts_with?(rel, &1))
      end)

    (source ++ docs)
    |> Enum.reject(&(&1 == @self_path))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp wildcard(root, globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.reject(&String.contains?(&1, "/_build/"))
    |> Enum.reject(&String.contains?(&1, "/deps/"))
    |> Enum.reject(&String.contains?(&1, "/node_modules/"))
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {top, 0} ->
        String.trim(top)

      _ ->
        cwd = File.cwd!()
        if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
    end
  end
end
