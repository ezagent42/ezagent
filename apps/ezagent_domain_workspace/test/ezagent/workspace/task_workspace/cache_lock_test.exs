defmodule Ezagent.Workspace.TaskWorkspace.CacheLockTest do
  use ExUnit.Case, async: false

  alias Ezagent.Workspace.TaskWorkspace.CacheLock

  test "waiting for an owned cache key is bounded" do
    parent = self()

    holder =
      spawn_link(fn ->
        CacheLock.with_lock("bounded-cache", 1_000, fn ->
          send(parent, :lock_held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :lock_held

    assert {:error, :cache_lock_timeout} =
             CacheLock.with_lock("bounded-cache", 10, fn -> flunk("lock acquired") end)

    send(holder, :release)
  end
end
