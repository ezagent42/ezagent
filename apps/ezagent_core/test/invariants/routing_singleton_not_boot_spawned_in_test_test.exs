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
  `:test`") is violated — via a STATIC check of the boot code:
  `register_system_kind/0` must guard the eager spawn with a test-env check
  (the `if is_test?() do :ok else …` block). Deleting that guard
  re-introduces the boot-time no-owner read/write.

  NOTE (codex P1): a RUNTIME `KindRegistry.lookup` check is deliberately NOT
  used — the suite DRAINS rather than terminates Kinds, so a test that
  demand-spawns `system://routing/default` earlier leaves it globally
  registered. A runtime refute would then check *current suite state*, not
  *boot state*, and flake under randomized ordering. The static source gate
  is the correct, order-independent invariant.
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
end
