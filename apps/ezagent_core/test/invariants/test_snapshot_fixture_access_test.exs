defmodule Ezagent.Invariants.TestSnapshotFixtureAccessTest do
  @moduledoc """
  Gates #20: ordinary tests seed snapshot rows through
  `Ezagent.Test.SnapshotFixtures`, not by scattering direct calls to
  `Ezagent.Kind.Snapshot.save_now/3` or `Ezagent.Ecto.KindSnapshot.upsert/5`.

  Tests that explicitly verify the low-level persistence primitives stay in the
  allowlist. Everything else should use the fixture helper so future changes to
  test snapshot seeding have one place to evolve.
  """

  use ExUnit.Case, async: true

  @direct_snapshot_write ~r/(?:Ezagent\.Kind\.Snapshot|Snapshot)\.save_now\s*\(|(?:Ezagent\.Ecto\.KindSnapshot|KindSnapshot)\.upsert\s*\(/

  @allowlist MapSet.new([
               # The new fixture helper is the one sanctioned test writer.
               "apps/ezagent_core/test/support/snapshot_fixtures.ex",
               # Tests for the low-level snapshot APIs themselves.
               "apps/ezagent_core/test/ezagent/lifecycle_followup_test.exs",
               "apps/ezagent_core/test/ezagent/lifecycle_test.exs",
               "apps/ezagent_core/test/ezagent/kind/snapshot_test.exs",
               # P1 KindBase round-trip test deliberately exercises the
               # low-level save_now/load_or_init persistence primitive to prove
               # the :kind_base instance set survives a snapshot round-trip.
               "apps/ezagent_core/test/ezagent/behavior/kind_base_test.exs",
               # P1 instance-set denial suite drives save_now/load_or_init
               # DIRECTLY because it tests the LOAD PATH itself — first-spawn
               # scoping, reload-derives-from-persisted-:kind_base, legacy
               # pre-P1 snapshot migration (hand-written :kind_base-less row),
               # and unclosed-set no-partial-persist. These ARE the low-level
               # persistence primitive under test, not fixture seeding.
               "apps/ezagent_core/test/ezagent/kind/instance_set_denial_test.exs",
               "apps/ezagent_core/test/ezagent/snapshot_store_test.exs",
               "apps/ezagent_core/test/integration/snapshot_restart_test.exs",
               "apps/ezagent_core/test/invariants/kind_snapshot_concurrent_upsert_test.exs",
               "apps/ezagent_core/test/invariants/no_silent_workspace_in_writers_test.exs",
               "apps/ezagent_core/test/invariants/lifecycle_persistence_access_test.exs",
               "apps/ezagent_core/test/invariants/test_snapshot_fixture_access_test.exs",
               # #189 PR-3 FIX 4 — the Session self-license migration test SEEDS
               # pre-cutover session snapshot fixtures via the low-level
               # `KindSnapshot.upsert/6` (it must control `mark_ever_created` +
               # the exact `:kind_base`/`:identity`/marker-only shapes the
               # migration classifies). It lives in the session domain, which
               # cannot reach the core-only `SnapshotFixtures` support module —
               # same rationale as the kind_base_backfill / curl migration tests.
               "apps/ezagent_domain_session/test/ezagent/socialware/session_self_license_migration_test.exs",
               # #189 release-runnable cutover Runbook test — proves the
               # Runbook's `apply/3` dispatch to the session domain's
               # self-license migration ACTUALLY RUNS end-to-end by seeding one
               # genuinely pre-cutover session snapshot (same
               # `mark_ever_created` + `:kind_base`-without-SelfLicense shape as
               # the session migration test above). Lives in the identity
               # domain, which likewise cannot reach the core-only
               # `SnapshotFixtures` support module (cross-app).
               "apps/ezagent_domain_identity/test/ezagent/identity/cutover/runbook_test.exs"
             ])

  test "ordinary tests use SnapshotFixtures for direct snapshot fixture writes" do
    apps_root = Path.expand("../../../..", __DIR__)

    violations =
      apps_root
      |> list_test_files()
      |> Enum.map(&Path.relative_to(&1, apps_root))
      |> Enum.reject(&MapSet.member?(@allowlist, &1))
      |> Enum.filter(fn rel_path ->
        @direct_snapshot_write
        |> Regex.match?(strip_line_comments(Path.join(apps_root, rel_path)))
      end)

    assert violations == [],
           """
           Test snapshot fixture writes must go through Ezagent.Test.SnapshotFixtures.

           Direct low-level snapshot writes found in:
           #{Enum.map_join(violations, "\n", &"  - #{&1}")}

           If a file is explicitly testing the low-level persistence primitive,
           add it to this invariant's allowlist with a short justification.
           Otherwise replace the call with SnapshotFixtures.save_kind_snapshot/3
           or SnapshotFixtures.upsert_kind_snapshot/5.
           """
  end

  defp list_test_files(apps_root) do
    apps_root
    |> Path.join("apps")
    |> File.ls!()
    |> Enum.flat_map(fn app ->
      test_dir = Path.join([apps_root, "apps", app, "test"])

      if File.dir?(test_dir) do
        list_elixir_files(test_dir)
      else
        []
      end
    end)
  end

  defp list_elixir_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.dir?(path) -> list_elixir_files(path)
        String.ends_with?(entry, ".ex") or String.ends_with?(entry, ".exs") -> [path]
        true -> []
      end
    end)
  end

  defp strip_line_comments(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end
end
