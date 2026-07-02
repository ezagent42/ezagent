defmodule EzagentCore.Invariants.NoConfigSchemeSubjectTest do
  @moduledoc """
  Elimination gate for the ConfigStore pseudo-URI subject `config://<ws>/<kind>/<name>`
  (SPEC `docs/together/2026-07-02/specs/T1-preprod-foundation.md`, project B).

  The definition/recipe ConfigStore subject used to LOOK like a URI
  (`config://<ws>/socialware/<name>` / `config://<ws>/recipe/<name>`) but:
  (a) `config` is not a registered scheme (`Ezagent.URI.new!/1` raises on it),
  (b) it is never parsed by `Ezagent.URI`, (c) it is never cross-referenced by
  any real-scheme object. It was a *pseudo* URI that violated the "every URI
  goes through Ezagent.URI" gate intent.

  B replaced it with a structured NON-URI subject `"<kind>:<name>"`
  (`recipe:<name>` / `socialware:<name>`) — an opaque string, matched exactly by
  ConfigStore, with workspace carried as a SEPARATE ConfigStore field (the
  `(layer, workspace_uri, subject, key)` tuple already scopes by workspace).

  This gate hard-fails if the retired `config://` pseudo-scheme reappears
  anywhere in `apps` source (code OR docstring OR comment — B's DoD is
  `grep -rn "config://" apps == 0`). It complements the general unknown-scheme
  gate (project C) which blocks `config://` in production code paths; this one
  additionally keeps it out of docstrings/comments.

  Real entity-URI subjects (agent config uses `agent_uri`, socialware install
  uses `session_uri`) are UNAFFECTED — B only retired the `config://` pseudo-URI
  subject builders.
  """

  use ExUnit.Case, async: true

  # This gate + the uri_query scan test legitimately NAME `config://` as a
  # fixture: the gate to describe what it forbids, the scan test to prove the
  # unknown-scheme catch-all (T1-C) flags a retired `config://` literal.
  @sanctioned [
    "apps/ezagent_core/test/invariants/no_config_scheme_subject_test.exs",
    "apps/ezagent_core/test/ezagent/uri_query/scan_test.exs",
    # The T1-D recipe-sense-role gate legitimately names the retired
    # config-scheme role URI segment in its forbidden-pattern regex to enforce
    # its OWN elimination.
    "apps/ezagent_core/test/invariants/no_recipe_sense_role_test.exs"
  ]

  test "no apps source references the retired config:// pseudo-URI subject" do
    root = repo_root()

    offenders =
      ["apps/*/lib/**/*.ex", "apps/*/lib/**/*.exs", "apps/*/test/**/*.ex", "apps/*/test/**/*.exs"]
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
      |> Enum.reject(&String.contains?(&1, "/_build/"))
      |> Enum.reject(&String.contains?(&1, "/deps/"))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 in @sanctioned))
      |> Enum.filter(fn rel -> File.read!(Path.join(root, rel)) =~ "config://" end)
      |> Enum.uniq()
      |> Enum.sort()

    assert offenders == [],
           "config:// pseudo-URI subject leak — these files still reference it:\n" <>
             Enum.join(offenders, "\n") <>
             "\n\nConfigStore subjects for definition/recipe are the structured " <>
             "non-URI form \"<kind>:<name>\" (recipe:<name> / socialware:<name>). " <>
             "Build them via DefinitionRegistry.definition_subject_uri/2 or " <>
             "RecipeRegistry.recipe_subject_uri/2 — never a config:// string."
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
