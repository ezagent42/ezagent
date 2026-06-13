defmodule Ezagent.Invariants.RoutingSingletonNotBootSpawnedInTestTest do
  @moduledoc """
  #52 Mode-B GATE (G2). Pins the test-isolation-race fix: the
  `system://routing/default` System routing sentinel MUST NOT be EAGERLY
  spawned at application boot under `Mix.env() == :test`.

  ## Why this is the architectural invariant

  `EzagentCore.Application.register_system_kind/0` used to unconditionally
  `SpawnRegistry.spawn(system://routing/default)` at boot. That spawn runs
  `Ezagent.Kind.Server.init/1` → a `kind_snapshots` READ
  (`Snapshot.load_or_init`) + a `persist_initial_snapshot/3` WRITE — BEFORE
  any test's `Ecto.Adapters.SQL.Sandbox` owner exists. In manual mode the
  supervisor-tree pid has no allowed connection, so that DB work raises
  `DBConnection.OwnershipError`. The boot path SWALLOWS it
  (`StateRebuilder.snapshot_exists?/1` rescues + logs "snapshot lookup
  raised … treating as not-existing"), which is why the umbrella suite was
  green-but-noisy AND why the cold-restart-gate tests flaked: a restarted
  `:snapshot` Kind reads `kind_snapshots` in `init/1` before it registers
  in `KindRegistry`, so the test cannot `Sandbox.allow/3` it ahead of the
  read and it can only reach a connection via a foreign/reverted shared
  owner.

  The fix (mirroring the `@writers_skipped_in_test` Audit/Snapshot-writer
  precedent) gates the EAGER boot-spawn behind `not is_test?()`, KEEPING the
  Behavior registration + the `system://` SpawnRegistry fn (no DB touch).
  The sentinel is now DEMAND-spawned by the tests that need it, inside a
  checked-out sandbox owner.

  Per `feedback_completion_requires_invariant_test`, this gate FAILS when
  the architectural goal ("no DB-touching singleton spawns at boot in
  `:test`") is violated — not merely when the suite is red:

    a. STATIC: `register_system_kind/0` must guard the eager spawn with a
       test-env check (the `if is_test?() do :ok else …` block). Deleting
       that guard re-introduces the boot-time no-owner read/write.
    b. RUNTIME: in `:test`, `system://routing/default` must NOT already be
       live in `KindRegistry` at the point a test runs (nothing spawned it
       at boot). A test that needs it spawns it explicitly.
  """

  use ExUnit.Case, async: true

  @application_path Path.expand(
                      "../../lib/ezagent_core/application.ex",
                      __DIR__
                    )

  test "register_system_kind/0 guards the eager routing/default spawn behind a test-env check (static gate)" do
    source = File.read!(@application_path)

    # The eager `SpawnRegistry.spawn(uri)` for the routing sentinel must be
    # reachable ONLY in the non-test branch. We assert the guard exists:
    # an `if is_test?()` (or `unless is_test?()`) wrapping the lookup/spawn
    # in `register_system_kind/0`.
    assert source =~ ~r/if\s+is_test\?\(\)\s+do\s*\n\s*:ok\s*\n\s*else/,
           """
           `register_system_kind/0` MUST gate the eager
           `SpawnRegistry.spawn(system://routing/default)` behind
           `is_test?()` (skip the boot-spawn in `:test`). Without it, the
           sentinel spawns at boot with no sandbox owner, re-introducing the
           `DBConnection.OwnershipError` cascade + cold-restart-gate flake
           (#52 Mode B). If you intentionally changed this, update this gate
           AND the demand-spawn setups in the routing tests AND the SPEC.
           """
  end

  test "in test env, system://routing/default is NOT live at boot (runtime gate)" do
    uri = Ezagent.Entity.System.routing_default_uri()

    refute match?({:ok, _pid}, Ezagent.KindRegistry.lookup(uri)),
           """
           `system://routing/default` must NOT be eagerly spawned at boot in
           `:test`. It was found live in KindRegistry with no test having
           spawned it — the boot-spawn guard (#52 Mode B) has regressed.
           Tests that need the sentinel demand-spawn it inside a checked-out
           sandbox owner (grep: routing_default_uri).
           """
  end
end
