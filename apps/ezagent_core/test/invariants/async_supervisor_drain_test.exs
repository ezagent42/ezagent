defmodule Ezagent.Invariants.AsyncSupervisorDrainTest do
  @moduledoc """
  Regression guard for the task #108-class async-escape flake (2026-07-11).

  The platform fans DB-touching work OFF a Kind's process into UNLINKED
  supervised Tasks under GLOBAL `Task.Supervisor`s — chiefly
  `Ezagent.Session.DeliverySupervisor` running
  `Delivery.deliver_async → ReadMarker.insert_marker`. Those Tasks are not in
  `KindRegistry`, so the old `drain_live_kinds` teardown never waited for
  them: when the test body returned and `stop_owner` reclaimed the shared
  connection, an in-flight Task either lost the connection mid-query
  (`is still using a connection from owner`) or found the pool reverted to
  `:manual` (`cannot find ownership process`) and its write was DROPPED —
  flaking any test that asserted the delivered effect, but only under the
  full-umbrella concurrency that widens the window.

  The fix registers each such supervisor (`register_async_drain_supervisor/1`)
  and teardown WAITS for its children before stopping the owner
  (`drain_async_supervisor/1`, exercised by the interleaved
  `drain_to_quiescence`). This gate asserts the WAIT actually blocks: a
  fire-and-forget child that does DB work after a delay must be COMPLETE by
  the time the drain returns. Delete the wait and the child is still running
  when `drain_async_supervisor/1` returns → the counter is 0 → this fails.
  """

  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  @sup DrainGuardTaskSup

  setup do
    start_supervised!(%{id: @sup, start: {Task.Supervisor, :start_link, [[name: @sup]]}})
    :ok
  end

  test "drain_async_supervisor blocks until a fire-and-forget DB-touching child completes" do
    done = :counters.new(1, [])

    log =
      capture_log(fn ->
        # A fire-and-forget delivery-shaped Task: delay, then do real DB work
        # on the shared sandbox connection, then record completion. `async_nolink`
        # mirrors `Ezagent.Session.DeliveryQueue`'s spawn shape.
        Task.Supervisor.async_nolink(@sup, fn ->
          Process.sleep(150)
          # Proves the child can reach the connection in shared mode AND that
          # the write commits before the owner is reclaimed. A dropped/broken
          # connection would crash here → counter stays 0 → the assert below fails.
          _ = EzagentCore.Repo.query!("SELECT 1")
          :counters.add(done, 1, 1)
        end)

        # The child is still in its delay: nothing done yet.
        assert :counters.get(done, 1) == 0,
               "child completed before the drain — test timing is wrong, not a real check"

        # THE GATE: the drain must not return until the child has finished.
        assert EzagentCore.DataCase.drain_async_supervisor(@sup) == :ok

        assert :counters.get(done, 1) == 1, """
        Async-escape drain REGRESSED: drain_async_supervisor/1 returned while a
        fire-and-forget child was still running. In the real suite this is the
        window where a delivery Task's write outlives the sandbox owner and is
        dropped — the exact #108-class flake this guard protects.
        """

        # The supervisor is now empty.
        assert Task.Supervisor.children(@sup) == []
      end)

    refute log =~ "cannot find ownership process",
           "sandbox-owner noise leaked while draining the async supervisor:\n#{log}"

    refute log =~ "DBConnection.OwnershipError",
           "sandbox-owner noise leaked while draining the async supervisor:\n#{log}"
  end
end
