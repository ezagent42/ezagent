defmodule Ezagent.ReadyGateTest do
  # Not async — shares the global ETS table.
  use ExUnit.Case
  alias Ezagent.ReadyGate

  setup do
    # Each test uses a unique URI so we don't trip on prior state.
    uri = "entity://team-alpha/agent/test_ready-gate-test-#{System.unique_integer([:positive])}"
    {:ok, uri: uri}
  end

  test "status defaults to :unknown for unseen URIs", %{uri: uri} do
    assert ReadyGate.status(uri) == :unknown
  end

  test "put/2 + status/1 round-trip", %{uri: uri} do
    :ok = ReadyGate.put(uri, :not_ready)
    assert ReadyGate.status(uri) == :not_ready

    :ok = ReadyGate.put(uri, :ready)
    assert ReadyGate.status(uri) == :ready
  end

  test "mark_ready/1 is a put with :ready", %{uri: uri} do
    :ok = ReadyGate.put(uri, :not_ready)
    :ok = ReadyGate.mark_ready(uri)
    assert ReadyGate.status(uri) == :ready
  end

  test "accepts both URI struct and string keys", %{uri: uri_str} do
    parsed = Ezagent.URI.new!(uri_str)
    :ok = ReadyGate.put(parsed, :ready)
    # Reading back via string form returns the same value.
    assert ReadyGate.status(uri_str) == :ready
  end

  describe "await/2 (codex E2E fix v2 Bug A, 2026-05-29)" do
    test "returns :ok immediately when URI is already :ready", %{uri: uri} do
      :ok = ReadyGate.put(uri, :ready)
      started = System.monotonic_time(:millisecond)
      assert :ok = ReadyGate.await(uri, 500)
      elapsed = System.monotonic_time(:millisecond) - started
      # No polling should be needed — first iteration's `status/1`
      # observation suffices.
      assert elapsed < 50
    end

    test "returns :ok after a delayed :ready flip within bound", %{uri: uri} do
      :ok = ReadyGate.put(uri, :not_ready)

      spawn(fn ->
        Process.sleep(50)
        :ok = ReadyGate.mark_ready(uri)
      end)

      started = System.monotonic_time(:millisecond)
      assert :ok = ReadyGate.await(uri, 500)
      elapsed = System.monotonic_time(:millisecond) - started
      # Flip lands at ~50ms; polling cadence is 10ms. So we expect
      # to return within (50 + ~20) ms — generous bound to tolerate
      # CI jitter.
      assert elapsed < 200
    end

    test "returns {:error, :timeout} when URI stays :not_ready past bound",
         %{uri: uri} do
      :ok = ReadyGate.put(uri, :not_ready)

      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = ReadyGate.await(uri, 50)
      elapsed = System.monotonic_time(:millisecond) - started
      # Bound was 50ms — the poll loop should respect the deadline.
      assert elapsed >= 50
      # And not run too far over (poll cadence is 10ms; tolerate one
      # extra iteration's worth of slop).
      assert elapsed < 200
    end

    test "returns {:error, :timeout} when URI stays :unknown past bound",
         %{uri: uri} do
      # No put/2 — the URI is truly unknown. `await/2` should NOT
      # treat unknown as ready (that would defeat the gate's purpose
      # for callers that just spawned the Kind).
      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = ReadyGate.await(uri, 30)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 30
    end

    test "accepts URI struct (not just string)", %{uri: uri_str} do
      parsed = Ezagent.URI.new!(uri_str)
      :ok = ReadyGate.put(parsed, :ready)
      assert :ok = ReadyGate.await(parsed, 50)
    end
  end
end
