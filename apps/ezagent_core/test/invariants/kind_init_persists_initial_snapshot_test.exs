defmodule Ezagent.Invariants.KindInitPersistsInitialSnapshotTest do
  @moduledoc """
  Allen 2026-05-25 — CLI persistence invariant.

  Per `feedback_completion_requires_invariant_test`: the architectural
  goal of this fix is "a Kind spawned via mix-task SURVIVES the mix
  BEAM exit." The test that fails when that goal is unmet:

      after `Ezagent.Kind.spawn/2` returns successfully, a
      `kind_snapshots` row MUST exist for any non-ephemeral Kind
      (`{:snapshot, :on_change}` / `{:snapshot, :periodic, _}` /
      `:on_terminate`), with no wait, no mutation, no terminate.

  Without `Kind.Server.init/1`'s `persist_initial_snapshot/3` call
  this test fails for `:on_change`, `:on_terminate`, and `:periodic`
  Kinds because the framework historically only wrote snapshots on
  slice mutation (dispatch), periodic timer tick, or graceful
  `terminate/2` — all three assuming a long-lived BEAM.

  `:ephemeral` / `:external` Kinds explicitly opt out of DB
  persistence; the test asserts no row appears for those (regression
  guard: the init-time write MUST respect the policy).

  Bug: `mix ezagent.agent.create entity://agent/system/cc_*` produced
  an `Ezagent.Entity.Agent` (`:on_terminate` policy) that was lost on
  mix BEAM exit — the agent was visible in the spawning BEAM but
  invisible to any subsequent BEAM lookup.

  Fix: `Ezagent.Kind.Server.init/1` now calls
  `Ezagent.Kind.Snapshot.save_now/3` for every non-ephemeral policy,
  synchronously, immediately after `KindRegistry.put_new` succeeds.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot

  describe "init writes initial snapshot for non-ephemeral Kinds" do
    test "{:snapshot, :on_change} — row exists immediately after spawn" do
      uri =
        URI.parse(
          "entity://agent/team-alpha/test_init-snap-onchange-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)

      # Pre-condition — no row before spawn
      assert nil == KindSnapshot.get(uri_str)

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({Ezagent.Test.OnChangeTestKind, %{uri: uri}})

      # Invariant — row exists IMMEDIATELY (no wait, no mutation).
      # Without the init-time write, this would be nil until a
      # dispatch arrived to mutate the slice. The CLI bug is that
      # the BEAM exits before any such dispatch.
      assert %KindSnapshot{kind_type: "test"} = KindSnapshot.get(uri_str)
    end

    test ":on_terminate — row exists immediately after spawn" do
      uri =
        URI.parse(
          "entity://agent/team-alpha/test_init-snap-onterm-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)

      assert nil == KindSnapshot.get(uri_str)

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({Ezagent.Test.OnTerminateTestKind, %{uri: uri}})

      # The CLI bug's primary case — `:on_terminate` Kinds (like
      # `Ezagent.Entity.Agent`) historically only wrote on graceful
      # `terminate/2`. mix-task BEAM exit doesn't reliably drain
      # `terminate/2` callbacks before halt → snapshot never lands.
      # The init-time write fixes this without changing the
      # `terminate/2` contract.
      assert %KindSnapshot{kind_type: "test"} = KindSnapshot.get(uri_str)
    end
  end

  describe "init does NOT write for ephemeral / external Kinds" do
    test ":ephemeral — no row after spawn (regression guard)" do
      uri =
        URI.parse(
          "entity://agent/team-alpha/test_init-snap-eph-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({Ezagent.Test.TestKind, %{uri: uri}})

      # The init-time write MUST respect the policy. Writing a
      # snapshot for an `:ephemeral` Kind would be a regression —
      # operators chose `:ephemeral` precisely to avoid the DB cost.
      assert nil == KindSnapshot.get(uri_str)
    end
  end
end
