defmodule Ezagent.PendingDeliveryTest do
  use ExUnit.Case
  alias Ezagent.PendingDelivery

  setup do
    uri = "entity://team-alpha/agent/test_pending-test-#{System.unique_integer([:positive])}"
    {:ok, uri: uri}
  end

  test "buffer + flush in arrival order", %{uri: uri} do
    :ok = PendingDelivery.buffer(uri, :first)
    :ok = PendingDelivery.buffer(uri, :second)
    :ok = PendingDelivery.buffer(uri, :third)

    assert PendingDelivery.flush(uri) == [:first, :second, :third]
  end

  test "flush after flush returns empty", %{uri: uri} do
    :ok = PendingDelivery.buffer(uri, :one)
    assert PendingDelivery.flush(uri) == [:one]
    assert PendingDelivery.flush(uri) == []
  end

  test "buffer_size/1 tracks count", %{uri: uri} do
    assert PendingDelivery.buffer_size(uri) == 0
    :ok = PendingDelivery.buffer(uri, :a)
    :ok = PendingDelivery.buffer(uri, :b)
    assert PendingDelivery.buffer_size(uri) == 2
  end

  test "overflow at max_per_uri returns :buffer_full", %{uri: uri} do
    max = PendingDelivery.max_per_uri()
    # Fill up to capacity — each call should succeed.
    for i <- 1..max do
      assert :ok = PendingDelivery.buffer(uri, {:msg, i})
    end

    # Next one should fail.
    assert {:error, :buffer_full} = PendingDelivery.buffer(uri, :overflow)
    # Buffer still at max.
    assert PendingDelivery.buffer_size(uri) == max
  end

  test "URI struct and string keys interoperate", %{uri: uri_str} do
    parsed = Ezagent.URI.new!(uri_str)
    :ok = PendingDelivery.buffer(parsed, :via_struct)
    # Same logical URI, look up via string.
    assert PendingDelivery.flush(uri_str) == [:via_struct]
  end
end
