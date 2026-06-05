defmodule EzagentCore.Invariants.RepoRootCleanTest do
  @moduledoc """
  Phase 6 PR 1 invariant — the dev SQLite DB must not live in the repo
  working tree. `mix ezagent.home.adopt_db` moves it to
  `$EZAGENT_HOME/<profile>/db/ezagent_core.db`; this test fails if it ever
  comes back.

  Test DBs (`ezagent_core_test.db*`) are allowed — config/test.exs still
  uses repo-root for Sandbox-pool ephemerality, and the `.gitignore`
  rule `*.db` keeps them out of commits anyway.
  """
  use ExUnit.Case, async: true

  @forbidden ["ezagent_core_dev.db", "ezagent_core_dev.db-shm", "ezagent_core_dev.db-wal"]

  test "no dev DB files exist at repo root" do
    repo_root = repo_root()

    leftovers =
      @forbidden
      |> Enum.map(&Path.join(repo_root, &1))
      |> Enum.filter(&File.exists?/1)

    assert leftovers == [],
           """
           Found dev DB files in repo working tree:
           #{Enum.map_join(leftovers, "\n", &"  - #{&1}")}

           Run `mix ezagent.home.adopt_db` to move them to $EZAGENT_HOME/<profile>/db/.
           """
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
