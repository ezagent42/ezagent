defmodule Ezagent.PendingDeliveryTest do
  use ExUnit.Case
  alias Ezagent.PendingDelivery

  setup do
    uri = "entity://team-alpha/agent/test_pending-test-#{System.unique_integer([:positive])}"
    :ok = Ezagent.ReadyGate.put(uri, :unknown)

    on_exit(fn ->
      _ = PendingDelivery.flush(uri)
      :ok = Ezagent.ReadyGate.put(uri, :unknown)
    end)

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

  test "buffer_if_not_ready rechecks the gate inside the URI critical section", %{uri: uri} do
    kind_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(kind_pid, :kill) end)

    :ok = Ezagent.ReadyGate.put(uri, :not_ready)
    assert :ok = PendingDelivery.buffer_if_not_ready(uri, :while_not_ready)
    assert PendingDelivery.buffer_size(uri) == 1

    assert [:while_not_ready] = PendingDelivery.flush(uri)
    :ok = Ezagent.ReadyGate.mark_ready(uri)
    assert {:retry, :ready} = PendingDelivery.buffer_if_not_ready(uri, :too_late)
    assert PendingDelivery.buffer_size(uri) == 0

    :ok = Ezagent.ReadyGate.mark_failed(uri)
    assert {:error, :failed} = PendingDelivery.buffer_if_not_ready(uri, :after_failure)
    assert PendingDelivery.buffer_size(uri) == 0
  end

  test "a stale not-ready gate with no registered Kind cannot retain a future entry", %{uri: uri} do
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    assert {:error, :incarnation_changed} =
             PendingDelivery.buffer_if_not_ready(uri, :future_authority)

    assert PendingDelivery.buffer_size(uri) == 0
  end

  test "concurrent buffers never overwrite one another", %{uri: uri} do
    parent = self()

    tasks =
      for value <- 1..50 do
        Task.async(fn ->
          send(parent, {:buffer_ready, self()})

          receive do
            :go -> PendingDelivery.buffer(uri, value)
          end
        end)
      end

    task_pids = Enum.map(tasks, & &1.pid)

    for _ <- task_pids do
      assert_receive {:buffer_ready, pid}, 1_000
      assert pid in task_pids
    end

    Enum.each(task_pids, &send(&1, :go))
    assert Enum.all?(tasks, &(Task.await(&1, 1_000) == :ok))

    assert PendingDelivery.buffer_size(uri) == 50
    assert uri |> PendingDelivery.flush() |> Enum.sort() == Enum.to_list(1..50)
  end

  test "an in-flight old-incarnation entry cannot buffer into a replacement Kind", %{uri: uri} do
    old_pid = register_fake_kind(uri)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    Process.exit(old_pid, :kill)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)

    new_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(new_pid, :kill) end)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    assert {:error, :incarnation_changed} =
             PendingDelivery.buffer_if_not_ready(uri, :old_authority, old_pid)

    assert PendingDelivery.buffer_size(uri) == 0
  end

  test "an in-flight old-incarnation entry cannot retry into a ready replacement", %{uri: uri} do
    old_pid = register_fake_kind(uri)
    :ok = Ezagent.ReadyGate.put(uri, :not_ready)

    Process.exit(old_pid, :kill)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)

    new_pid = register_fake_kind(uri)
    on_exit(fn -> Process.exit(new_pid, :kill) end)
    :ok = Ezagent.ReadyGate.mark_ready(uri)

    assert {:error, :incarnation_changed} =
             PendingDelivery.buffer_if_not_ready(uri, :old_authority, old_pid)

    assert PendingDelivery.buffer_size(uri) == 0
  end

  defp register_fake_kind(uri) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Ezagent.KindRegistry.put_new(uri)
        send(parent, {:fake_kind_registered, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:fake_kind_registered, ^pid}, 1_000
    pid
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
