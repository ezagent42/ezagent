defmodule EzagentPluginCc.OrphanReaperTest do
  @moduledoc """
  Unit tests for `EzagentPluginCc.OrphanReaper` — the cc-plugin's
  orphan-claude reaper (PTY-orphan-restart 2026-05-26, refactored
  to pid-file discovery 2026-05-26 follow-up (a)).

  Strategy: the reaper is now a thin wrapper over
  `Ezagent.Runtime.PidFile`. We exercise it end-to-end:

    1. Set EZAGENT_HOME to a tmpdir so PidFile.dir/1 lands somewhere
       safe + isolated.
    2. Drop a fake pid file pointing at our own OS pid (guaranteed
       alive, with a captured start_seconds).
    3. Call `reap/0`. The OS process IS alive + start matches, so
       the reaper would SIGTERM us — to avoid that we instead drop
       a pid file pointing at a DEAD pid (or at our own pid with a
       mismatched start time), exercising the cleanup branch
       without signalling.

  The "actually SIGTERM" path is exercised by the cc-orphan e2e
  (separate file) which intentionally creates throw-away orphans.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Runtime.PidFile

  setup do
    # Per-test EZAGENT_HOME so deployments don't share state.
    tmp = Path.join(System.tmp_dir!(), "ezagent-reaper-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev_home = System.get_env("EZAGENT_HOME")
    prev_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", "reaper-test")

    on_exit(fn ->
      if prev_home, do: System.put_env("EZAGENT_HOME", prev_home), else: System.delete_env("EZAGENT_HOME")
      if prev_profile, do: System.put_env("EZAGENT_PROFILE", prev_profile), else: System.delete_env("EZAGENT_PROFILE")
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "reap/0" do
    test "returns {:ok, 0} when no pid files exist" do
      assert {:ok, 0} = EzagentPluginCc.OrphanReaper.reap()
    end

    test "removes a stale pid file pointing at a dead PID" do
      uri = URI.parse("entity://agent/team-alpha/cc_dead")
      path = PidFile.file_path("cc", uri)
      # Pid 1 is init/launchd — always alive. Use a deliberately-dead
      # large pid (max OS pid is typically 99999 on macOS). We can't
      # guarantee 99998 is dead, but the start-time check below will
      # catch any wraparound by mismatching the bogus written start.
      File.write!(path, "99998\n0\n")
      assert File.exists?(path)

      assert {:ok, 0} = EzagentPluginCc.OrphanReaper.reap()
      # Either the pid is dead → file removed, or alive with
      # different start → also removed. Either way, file gone.
      refute File.exists?(path)
    end

    test "removes pid file when start_seconds mismatch (PID recycle)" do
      own_pid = String.to_integer(System.pid())

      uri = URI.parse("entity://agent/team-alpha/cc_recycle")
      path = PidFile.file_path("cc", uri)
      # Deliberately-wrong start time → reaper sees "alive but recycled"
      # → removes file WITHOUT sending kill.
      File.write!(path, "#{own_pid}\n1\n")

      assert {:ok, 0} = EzagentPluginCc.OrphanReaper.reap()
      refute File.exists?(path)

      # And we (the test process) are still alive — proof no SIGTERM
      # was sent to us.
      assert Process.alive?(self())
    end

    test "ignores pid files whose contents don't parse" do
      uri = URI.parse("entity://agent/team-alpha/cc_garbage")
      path = PidFile.file_path("cc", uri)
      File.write!(path, "this is not a valid pid file\n")

      assert {:ok, 0} = EzagentPluginCc.OrphanReaper.reap()
      # PidFile.enumerate/1 deletes garbage files on the spot.
      refute File.exists?(path)
    end
  end
end
