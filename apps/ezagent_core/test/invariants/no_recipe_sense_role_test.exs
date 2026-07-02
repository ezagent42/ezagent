defmodule EzagentCore.Invariants.NoRecipeSenseRoleTest do
  @moduledoc """
  Elimination gate for the recipe-sense `role` residue
  (SPEC `docs/together/2026-07-02/specs/T1-preprod-foundation.md`, project D —
  completing the #127/#141 role→recipe rename).

  #127 already renamed the module `Ezagent.Role` → `Ezagent.Agent.Recipe` and the
  storage layer to `key = "recipe"`. What lingered was the **recipe-sense** word
  `role` in identifiers + persisted URI segments:

    * the `orchestrator_role` identifier family (module `OrchestratorRole`,
      `resolve_orchestrator_role`, `apply_orchestrator_role_bootstrap`, …) —
      the orchestrator's RECIPE, now `orchestrator_recipe` / `OrchestratorRecipe`.
    * the `template://<ws>/role/<name>` (and `config://<ws>/role/<name>`) URI
      segment for the recipe-carrier Template → `.../recipe/<name>`.

  ## CRITICAL: this is the recipe-sense `role` ONLY

  The **routing-sense** role vocabulary is a DIFFERENT, load-bearing concept
  (a per-session unique routing identifier) and is deliberately PRESERVED — this
  gate must NOT flag any of it:

    `role_name`, `{:role, name}`, the `$role:` receiver prefix, `RoleResolver`,
    `role_seed_hook`, `role_step`.

  The forbidden patterns below are narrow (the `orchestrator_role` identifier and
  the `<scheme>://.../role/` recipe-URI segment) precisely so the routing
  vocabulary above never matches.

  Frozen historical design-doc trees are allowlisted (they describe the prior
  state / the rename); living source + docs are scanned.
  """

  use ExUnit.Case, async: true

  @forbidden [
    {~r/orchestrator_role/i, "recipe-sense `orchestrator_role` identifier (use orchestrator_recipe)"},
    {~r/template:\/\/[^\/\s]+\/role\//, "recipe-sense `template://.../role/` URI segment (use .../recipe/)"},
    {~r/config:\/\/[^\/\s]+\/role\//, "recipe-sense `config://.../role/` URI segment (use .../recipe/)"}
  ]

  @self_path "apps/ezagent_core/test/invariants/no_recipe_sense_role_test.exs"

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
    "scripts/**/*.ex",
    "scripts/**/*.exs"
  ]

  @doc_globs ["*.md", "docs/**/*.md"]

  test "no source or living doc carries recipe-sense role residue (routing role_name preserved)" do
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
           "recipe-sense role residue (T1-D) — rename to recipe:\n" <>
             Enum.join(offenders, "\n") <>
             "\n\nNOTE: routing-sense role_name / {:role, _} / $role: / RoleResolver / " <>
             "role_seed_hook / role_step are PRESERVED and are not matched here."
  end

  defp scanned_files(root) do
    source =
      @source_globs
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))

    docs =
      @doc_globs
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
      |> Enum.reject(fn abs ->
        rel = Path.relative_to(abs, root)
        Enum.any?(@historical_doc_prefixes, &String.starts_with?(rel, &1))
      end)

    (source ++ docs)
    |> Enum.reject(&String.contains?(&1, "/_build/"))
    |> Enum.reject(&String.contains?(&1, "/deps/"))
    |> Enum.reject(&String.contains?(&1, "/node_modules/"))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&(&1 == @self_path))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {top, 0} -> String.trim(top)
      _ -> cwd = File.cwd!(); if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
    end
  end
end
