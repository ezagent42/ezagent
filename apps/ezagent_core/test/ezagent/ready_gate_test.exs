defmodule Ezagent.ReadyGateTest do
  # Not async — shares the global ETS table.
  use ExUnit.Case
  alias Ezagent.ReadyGate

  setup do
    # Each test uses a unique URI so we don't trip on prior state.
    uri = "entity://agent/team-alpha/test_ready-gate-test-#{System.unique_integer([:positive])}"
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
    parsed = URI.parse(uri_str)
    :ok = ReadyGate.put(parsed, :ready)
    # Reading back via string form returns the same value.
    assert ReadyGate.status(uri_str) == :ready
  end
end
