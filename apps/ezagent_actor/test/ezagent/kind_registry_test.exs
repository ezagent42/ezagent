defmodule Ezagent.KindRegistryTest do
  use ExUnit.Case
  alias Ezagent.KindRegistry

  test "put_new + lookup round-trip from same process" do
    uri = "entity://team-alpha/agent/test_kr-test-#{System.unique_integer([:positive])}"

    # Same process registers itself.
    assert :ok = KindRegistry.put_new(uri)
    assert {:ok, pid} = KindRegistry.lookup(uri)
    assert pid == self()
  end

  test "lookup returns :error for unregistered URI" do
    assert :error =
             KindRegistry.lookup(
               "entity://team-alpha/agent/test_nonexistent-#{System.unique_integer([:positive])}"
             )
  end

  test "duplicate put_new returns {:error, {:already_registered, pid}}" do
    uri = "entity://team-alpha/agent/test_kr-dup-#{System.unique_integer([:positive])}"

    # Spawn a process to register first and stay alive.
    parent = self()

    {first_pid, ref} =
      spawn_monitor(fn ->
        :ok = KindRegistry.put_new(uri)
        send(parent, :registered)
        # Stay alive until told to exit.
        receive do
          :exit -> :ok
        end
      end)

    assert_receive :registered

    # From our process, attempt to re-register.
    assert {:error, {:already_registered, ^first_pid}} = KindRegistry.put_new(uri)

    send(first_pid, :exit)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _}
  end

  test "list_all includes our registration" do
    uri = "entity://team-alpha/agent/test_kr-list-#{System.unique_integer([:positive])}"
    :ok = KindRegistry.put_new(uri)

    entries = KindRegistry.list_all()
    assert Enum.any?(entries, fn {k, pid} -> k == uri and pid == self() end)
  end
end
