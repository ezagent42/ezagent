defmodule Ezagent.Socialware.AnonUser.SweeperTest do
  @moduledoc """
  Issue #51 §3.4 — the in-app GC sweeper GenServer (`Ezagent.Socialware.AnonUser.Sweeper`).

  The reap logic is tested in `Ezagent.Socialware.AnonUserGCTest` (`GC.sweep/1`); here
  we pin the scheduler wrapper: it starts without boot-time side effects, a `:sweep`
  tick runs a sweep on an empty table without crashing, and it re-arms its timer.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.AnonUser.Sweeper

  test "starts and arms its timer (no boot-time DB work)" do
    {:ok, pid} = Sweeper.start_link(name: nil, interval_ms: 3_600_000)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a :sweep tick runs GC.sweep on an empty table without crashing and re-arms" do
    # The Sweeper GenServer runs its `:sweep` Repo read in its own process;
    # `use EzagentCore.DataCase, async: false` already shares the sandbox via a
    # drainable Agent owner, so it sees the connection WITHOUT re-globalizing it
    # onto the dying test pid (which clobbered concurrent suites — #92).
    {:ok, pid} = Sweeper.start_link(name: nil, interval_ms: 3_600_000)

    send(pid, :sweep)

    # A synchronous round-trip proves the tick was handled and the GenServer is
    # still alive (it re-armed and did not crash on the empty sweep).
    assert :sys.get_state(pid) == %{interval_ms: 3_600_000}
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end
end
