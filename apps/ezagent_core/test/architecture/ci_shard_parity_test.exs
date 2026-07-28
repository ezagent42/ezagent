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

  test "the ci.yml full-suite matrix lists exactly the manifest shards + static" do
    # STEP/NAME/FILE parity (ci.shard.verify + the tests above) prove the mix.exs
    # aliases and the manifest agree — but the `.github/workflows/ci.yml` matrix
    # `shard: [...]` is a HAND-MAINTAINED list with NO other gate. A shard added to
    # ci_shards.exs but missing from the matrix would be SILENTLY not run in CI
    # (the exact "silent cap" this repo forbids). Pin both sides here.
    ci_yml = Path.join(CiShards.repo_root(), ".github/workflows/ci.yml")
    source = File.read!(ci_yml)

    [_, list] = Regex.run(~r/^\s*shard:\s*\[([^\]]+)\]/m, source)

    matrix =
      list
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    want = MapSet.new(["static" | CiShards.shard_names()])

    assert MapSet.equal?(matrix, want),
           """
           .github/workflows/ci.yml `shard:` matrix drifted from ci_shards.exs.
             missing from ci.yml (would NOT run in CI): #{inspect(MapSet.to_list(MapSet.difference(want, matrix)))}
             extra in ci.yml (no matching shard alias):  #{inspect(MapSet.to_list(MapSet.difference(matrix, want)))}
           """
  end
end

defmodule EzagentCore.Architecture.NodeGlobalTeardownIsolationTest do
  @moduledoc """
  Empty-allowlist enumerator gate for the `domain_lifecycle` carve (see the
  `ci_shards.exs` manifest and `EzagentCore.CiShards`).

  The CI `domain` shard runs every domain app's tests in ONE shared BEAM. A test
  that performs NODE-GLOBAL OTP teardown — a whole-app `Application.stop(:ezagent_
  domain_*)`, or a kill of the node-global `EzagentCore.EtsOwner` (which owns the
  shared capability/behavior ETS tables) — is self-restoring for the app UNDER
  test but POISONS every other domain app scheduled after it in that BEAM. That is
  the #189 ~510-failure cascade (`absorb_not_committed`, `no process: *Registry`,
  ETS ArgumentError). Those files are carved into their OWN `domain_lifecycle` leg.

  This gate greps EVERY umbrella test file for the two proven node-global-teardown
  mechanisms and fails if ANY such file is assigned to a shard OTHER than
  `domain_lifecycle` — so a NEW aggressor cannot silently re-poison the shared
  domain shard. It is deliberately CONSERVATIVE: a false positive merely forces a
  file into the isolated leg (safe); a false negative would re-open the cascade.
  Test-scoped `Process.exit(pid, :kill)` of an app-LOCAL process (e.g. identity's
  `entity_caps_test.exs`, or provider_connection's `registry_test.exs` killing its
  own `DriverRegistry`) is NOT node-global and is correctly ignored.
  """
  use ExUnit.Case, async: true

  alias EzagentCore.CiShards

  # Any shard whose name ends in `_lifecycle` is a carved node-global-teardown
  # isolation leg (one aggressor per leg — see ci_shards.exs). Convention-derived
  # so adding a `*_lifecycle` leg needs no gate edit.
  @carved_suffix "_lifecycle"

  # This gate's OWN source names the teardown patterns (in the regexes + the
  # failure message), so it self-matches the detector. Exclude it — it is the
  # meta-test, not an aggressor. Captured as the compile-time path so a rename
  # cannot silently un-exclude (and mis-flag) it.
  @self_file __ENV__.file

  defp carved?(shard), do: is_binary(shard) and String.ends_with?(shard, @carved_suffix)

  # Whole-app stop of a domain application — tears down that app's OTP tree +
  # declarations node-wide.
  @whole_app_stop ~r/Application\.stop\(:ezagent_domain_/

  # A kill of the node-global core ETS owner. A file that both names
  # `EzagentCore.EtsOwner` AND brutally kills a process is treating the shared
  # owner as churn — poisoning every reader of the shared cap/behavior tables.
  @core_ets_owner ~r/EzagentCore\.EtsOwner/
  @brutal_kill ~r/Process\.exit\([^)]*:kill\)/

  defp node_global_teardown?(source) do
    Regex.match?(@whole_app_stop, source) or
      (Regex.match?(@core_ets_owner, source) and Regex.match?(@brutal_kill, source))
  end

  test "every node-global-teardown test file is carved into a *#{@carved_suffix} leg" do
    root = CiShards.repo_root()
    self_rel = Path.relative_to(@self_file, root)

    offenders =
      for file <- CiShards.all_test_files(),
          file != self_rel,
          node_global_teardown?(File.read!(Path.join(root, file))),
          not carved?(CiShards.assign(file)),
          do: {file, CiShards.assign(file)}

    assert offenders == [],
           """
           #{length(offenders)} test file(s) perform NODE-GLOBAL OTP teardown (whole-app \
           Application.stop(:ezagent_domain_*) or an EzagentCore.EtsOwner kill) but are NOT \
           in a carved `*#{@carved_suffix}` isolation leg — they would re-poison the shared \
           `domain` shard (the #189 cascade). Add each to its own `*#{@carved_suffix}` rule \
           in ci_shards.exs (one aggressor per leg):
           #{Enum.map_join(offenders, "\n", fn {f, shard} -> "  - #{f} (currently in: #{shard})" end)}
           """
  end

  test "every carved *#{@carved_suffix} leg is non-empty and holds exactly one aggressor" do
    # A rename that empties a carved leg would let the enumerator above pass
    # vacuously while the aggressor leaks back into `domain`. And since the whole
    # point of the split is that these aggressors CANNOT co-habit a BEAM, each
    # carved leg must hold EXACTLY ONE file — pin both here at the source.
    carved = Enum.filter(CiShards.shard_names(), &carved?/1)
    assert carved != [], "no `*#{@carved_suffix}` isolation leg exists — the #189 carve is gone."

    for leg <- carved do
      files = CiShards.files_for(leg)

      assert length(files) == 1,
             "`#{leg}` holds #{length(files)} files (expected exactly 1 — one aggressor per " <>
               "carved leg, they cross-poison a shared BEAM): #{inspect(files)}"
    end
  end
end
