defmodule EzagentCore.Architecture.CiShardParityTest do
  @moduledoc """
  FILE-parity gate for the CI full-suite shard split (see `EzagentCore.CiShards`
  and `.github/workflows/ci.yml`). Runs in the deterministic `gate.arch` subset,
  so EVERY PR proves the shard assignment still covers every umbrella test file.

  This is the empty-allowlist enumerator: it lists every test file the monolith
  `mix test` runs and asserts the shard rules assign each to exactly one shard. A
  new top-level app (or a renamed test tree) whose files match no rule fails here
  — forcing an explicit shard decision instead of a silently-dropped suite.

  STEP parity + NAME parity (that the union of shard *steps* equals `ci.local`)
  need the umbrella alias table, which is only the current project at the
  umbrella root — so they are enforced by `mix ci.shard.verify` (a `ci.shard.
  static` step + the coordinator's manual tool), not here.
  """
  use ExUnit.Case, async: true

  alias EzagentCore.CiShards

  test "every umbrella test file is assigned to exactly one shard (0 unassigned)" do
    report = CiShards.verify()

    assert report.unassigned == [],
           """
           #{length(report.unassigned)} test file(s) match NO shard rule in ci_shards.exs — \
           the full-suite would DROP them. Add a shard rule (or extend an existing one) so \
           every file is covered:
           #{Enum.map_join(report.unassigned, "\n", &"  - #{&1}")}
           """

    # assign/1 is total, so sum(shard counts) + unassigned == total; with 0
    # unassigned the shards are a lossless partition of the monolith test set.
    assert Enum.sum(Map.values(report.counts)) == report.total
    assert report.total > 0
  end

  test "no shard rule is stale (every shard matches at least one file)" do
    report = CiShards.verify()

    assert report.empty == [],
           "shard(s) #{inspect(report.empty)} matched 0 test files — a rule went stale " <>
             "(app removed/renamed). Fix or remove the rule in ci_shards.exs."
  end

  test "the known-red kb E2E test isolates into the e2e shard" do
    # Guards the task's headline value: the deterministic full-suite failure
    # (EzagentPluginKb.E2E.AutoserviceTier1SeedTest) lands in the re-runnable
    # `e2e` shard, not smeared across an app shard.
    file = "apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs"

    if file in CiShards.all_test_files() do
      assert CiShards.assign(file) == "e2e"
    end
  end
end
