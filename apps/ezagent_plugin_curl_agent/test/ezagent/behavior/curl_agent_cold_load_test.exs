defmodule Ezagent.ActionSet.CurlAgentColdLoadTest do
  @moduledoc """
  Phase B (2026-05-29) Lifecycle migration — cold-load round-trip gate
  for `Ezagent.ActionSet.CurlAgent` (representative example A, the simple
  no-transients case).

  SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6:
  the canonical `assert_transients_rebuilt/2` gate is N/A here because
  CurlAgent has NO transients (no PID / ETS / port / subprocess /
  monitor). The architectural property we MUST still pin for a
  no-transients module is the OTHER half of the two-container contract:

    `create/1` → PERSISTENT `state` → snapshot → cold-load REHYDRATES it
    (and `create/1` does NOT re-run on the cold-load — the ever-created
    marker gates it).

  This is the parity-relevant invariant: the migration must not silently
  drop the durable conversation / config that the old `init_slice` +
  snapshot path carried. The test FAILS if the converted module stops
  persisting its `:curl_agent` state, or if a cold-load wrongly re-runs
  `create/1` and clobbers the rehydrated state back to defaults.

  We drive the cold-load DETERMINISTICALLY via the production
  `Kind.spawn/2` entry: spawn → `Kind.terminate/1` (permanent removal,
  no auto-restart) → confirm the snapshot row survives → re-spawn the
  same URI (cold-load path: `ever_created?` true → create/1 SKIPPED →
  snapshot merge rehydrates state). Using `Kind.terminate/1` (which goes
  through the owning `DynamicSupervisor`) keeps the Kind process OFF the
  test process's link set, so the teardown never propagates an EXIT into
  the test.
  """

  # `EzagentCore.DataCase` (an in-umbrella `lib/` module — reachable from
  # this plugin app) gives the SQL sandbox so the `kind_snapshots` row
  # written at spawn is isolated + rolled back per test.
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.CurlAgent
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.{Kind, KindRegistry}

  @slice_key :curl_agent

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  test "create→state round-trips through a cold-load (state rehydrates; create does not re-run)" do
    uri =
      Ezagent.URI.new!("entity://team-alpha/agent/curl_coldload-#{System.unique_integer([:positive])}")

    uri_str = URI.to_string(uri)

    # Non-default args so the rehydrated state is distinguishable from a
    # wrongly-re-run `create/1` (which would reset to deepseek defaults).
    # PR-6+7 — a curl agent spawns on the UNIFIED `Entity.Agent` Kind with the
    # curl per-instance behavior set (the standalone curl Kind is deleted).
    spawn_args = %{
      uri: uri,
      behaviors: Ezagent.Entity.Agent.curl_behaviors(),
      provider: "openai",
      api_url: "https://api.openai.com/v1/chat/completions",
      model: "gpt-4o",
      system_prompt: "be terse",
      max_history: 7
    }

    # 1. Fresh spawn via the production entry (`Kind.spawn/2` →
    #    DynamicSupervisor child, NOT linked to the test process).
    #    `create/1` builds the PERSISTENT :curl_agent state;
    #    `Kind.Server.init/1` writes the initial snapshot ({:snapshot,
    #    :on_change} persists at init).
    {:ok, pid1} = Kind.spawn(Ezagent.Entity.Agent, spawn_args)
    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

    # T3 (Phase B foundation): `get_slice/2` now normalizes a two-container
    # slice to its flat `.state` view for production consumers. This test
    # asserts on BOTH containers (state + transients), so it reads the RAW
    # two-container slice the host GenServer holds.
    {:ok, %{state: state_before, transients: transients_before}} =
      Ezagent.Kind.SliceAccess.get_raw_slice(uri, @slice_key)

    # The expected persistent state == what create/1 built from the args.
    {:ok, created} = CurlAgent.create(spawn_args)
    assert state_before == created
    assert state_before.provider == "openai"
    assert state_before.model == "gpt-4o"
    assert state_before.system_prompt == "be terse"
    assert state_before.max_history == 7
    assert state_before.conversation == []

    # No transients — the no-transients property of this representative
    # example (so the cold-restart bug class does not apply here).
    assert transients_before == %{}

    # Snapshot row exists + the ever-created marker is set (so a cold-load
    # will SKIP create/1).
    assert %KindSnapshot{} = KindSnapshot.get(uri_str)
    assert KindSnapshot.ever_created?(uri_str)

    # 2. Permanent termination via the production teardown (goes through
    #    the owning DynamicSupervisor, so no auto-restart and no EXIT
    #    propagated to the test). The durable snapshot survives.
    ref = Process.monitor(pid1)
    :ok = Kind.terminate(uri)
    assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 2_000
    wait_until(fn -> KindRegistry.lookup(uri_str) == :error end)

    # The durable row + marker outlive the process.
    assert %KindSnapshot{} = KindSnapshot.get(uri_str)
    assert KindSnapshot.ever_created?(uri_str)

    # 3. Cold-load — re-spawn the same URI. `init_slice` sees
    #    `ever_created?/1` true → SKIPS create/1; the snapshot merge
    #    rehydrates the persistent state.
    {:ok, pid2} = Kind.spawn(Ezagent.Entity.Agent, %{uri: uri})
    refute pid1 == pid2
    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

    # T3: RAW read — assert on both containers (see note above).
    {:ok, %{state: state_after, transients: transients_after}} =
      Ezagent.Kind.SliceAccess.get_raw_slice(uri, @slice_key)

    # 4. State rehydrated correctly — the custom config + empty
    #    conversation survived, and create/1 did NOT re-run (which would
    #    have reset provider→"deepseek").
    assert state_after == state_before
    assert state_after.provider == "openai"
    assert state_after.max_history == 7

    # Still no transients on cold-load (activate is the no-op default).
    assert transients_after == %{}

    # Clean up the cold-load process so it doesn't outlive the test.
    Kind.terminate(uri)
  end
end
