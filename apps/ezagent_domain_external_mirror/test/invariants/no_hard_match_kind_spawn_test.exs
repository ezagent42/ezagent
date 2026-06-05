defmodule Ezagent.ExternalMirror.Invariants.NoHardMatchKindSpawnTest do
  @moduledoc """
  PR-EM-FINAL invariant 9.

  Per **P16** (single Kind spawn entry) AND SPEC §3.1 idempotency
  contract, `Ezagent.Kind.spawn/2` returns one of:

  - `{:ok, pid}` — fresh spawn
  - `{:error, {:already_started, pid}}` — concurrent winner / restart
    adoption (also success per idempotency)
  - `{:error, reason}` — real failure

  Pattern-matching `:ok = Kind.spawn(...)` (or `:ok = Ezagent.Kind.spawn(...)`)
  is ALWAYS a bug — `Kind.spawn/2` NEVER returns the bare `:ok`
  atom; the hard-match either CRASHES on every fresh spawn OR
  silently treats `{:already_started, _}` as a failure.

  ## Why a grep gate

  This regression has been written twice already (PR-EM-2 round-1 +
  PR-EM-3 round-1 both had it in different files). A grep gate is
  cheaper than catching it again at runtime in some specific
  integration test.

  ## Scope

  Greps `apps/ezagent_domain_external_mirror/` AND
  `apps/ezagent_domain_instance_message/` (where the Behavior's reconciliation
  loop spawns Workers). Plugins are NOT scoped because they should
  go through the `Ezagent.ExternalMirror.bind/4` facade, never
  `Kind.spawn` Workers directly.
  """
  use ExUnit.Case, async: true

  @forbidden_patterns [
    # `:ok = Kind.spawn(`
    ":ok\\s*=\\s*Kind\\.spawn\\(",
    # `:ok = Ezagent.Kind.spawn(`
    ":ok\\s*=\\s*Ezagent\\.Kind\\.spawn\\(",
    # `:ok = WorkerSpawn.spawn(`  (Worker-side bypass)
    ":ok\\s*=\\s*WorkerSpawn\\.spawn\\(",
    # `:ok = Ezagent.ExternalMirror.WorkerSpawn.spawn(`
    ":ok\\s*=\\s*Ezagent\\.ExternalMirror\\.WorkerSpawn\\.spawn\\("
  ]

  @scoped_dirs [
    "ezagent_domain_external_mirror/lib",
    "ezagent_domain_instance_message/lib"
  ]

  test "no `:ok = Kind.spawn(...)` (or equivalent) hard-matches in ExternalMirror + Chat lib" do
    violations =
      for dir <- @scoped_dirs, pattern <- @forbidden_patterns do
        full_dir = Path.join(apps_root(), dir)
        grep_one(full_dir, pattern)
      end
      |> List.flatten()

    assert violations == [],
           """
           Hard-match `:ok = Kind.spawn(...)` (or WorkerSpawn.spawn) found —
           violates PR-EM-FINAL invariant 9.

           `Kind.spawn/2` returns `{:ok, pid}` or `{:error,
           {:already_started, pid}}` — NEVER bare `:ok`. The hard match
           crashes on every fresh spawn AND treats the idempotent
           concurrent-winner case as failure. Use a `case` /
           `with`-pipeline accepting both shapes.

           Offenders:
           #{Enum.join(violations, "\n")}
           """
  end

  defp grep_one(dir, pattern) do
    {output, _exit} =
      System.cmd(
        "grep",
        ["-rEn", pattern, dir, "--include=*.ex"],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&comment_or_docstring?/1)
  end

  defp comment_or_docstring?(line) do
    case String.split(line, ":", parts: 3) do
      [_path, _lineno, body] ->
        trimmed = String.trim_leading(body)
        String.starts_with?(trimmed, "#")

      _ ->
        false
    end
  end

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
end
