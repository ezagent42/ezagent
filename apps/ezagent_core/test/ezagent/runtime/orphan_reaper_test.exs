defmodule Ezagent.Runtime.OrphanReaperTest do
  @moduledoc """
  Tests for the shared `Ezagent.Runtime.OrphanReaper` (Task 2, SPEC
  `2026-06-25-sidecar-erlexec-runtime.md` §3.4).

  `reap/1` is a plain function (NOT a GenServer/child_spec) called from
  each new sidecar plugin's `Application.after_boot/0`. It sweeps
  `PidFile.enumerate(plugin)` once and, per entry, applies the
  PID-recycle guard (recheck `process_start_seconds` vs the stored
  start):

    * match → adopt + stop (signal) the os_pid, then `PidFile.remove`.
    * mismatch / dead → `PidFile.remove` only (NO signal).

  The `@tag :slow` tests run REAL OS processes and poll `ps -p` (never
  `pkill`); `on_exit` reaps any leaked `sleep` so a failure doesn't leak.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Runtime.OrphanReaper
  alias Ezagent.Runtime.PidFile

  @plugin "feishu-ws"

  defp os_alive?(pid) when is_integer(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp eventually_dead?(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      cond do
        System.monotonic_time(:millisecond) > deadline -> :timeout
        os_alive?(os_pid) -> :alive
        true -> :dead
      end
    end)
    |> Enum.reduce_while(nil, fn
      :dead, _ -> {:halt, true}
      :timeout, _ -> {:halt, false}
      :alive, _ -> Process.sleep(200) && {:cont, nil}
    end)
  end

  # Spawn a real `sleep` and return its OS pid. Registered for cleanup.
  defp spawn_sleep(test_ctx) do
    # :exec.start/0 is idempotent — {:ok, _} first call, already_started after.
    case :exec.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _exec_pid, os_pid} = :exec.run(~c"/bin/sleep 300", [:monitor])

    ExUnit.Callbacks.on_exit(fn ->
      _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    _ = test_ctx
    os_pid
  end

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ezagent-orphanreaper-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    prev_home = System.get_env("EZAGENT_HOME")
    prev_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", "orphanreaper-test")

    on_exit(fn ->
      if prev_home,
        do: System.put_env("EZAGENT_HOME", prev_home),
        else: System.delete_env("EZAGENT_HOME")

      if prev_profile,
        do: System.put_env("EZAGENT_PROFILE", prev_profile),
        else: System.delete_env("EZAGENT_PROFILE")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "reap/1 — no pid files" do
    test "returns :ok with an empty subdir" do
      assert :ok = OrphanReaper.reap(@plugin)
    end
  end

  describe "reap/1 — dead / recycled entries (no signal, fast)" do
    test "removes a stale pid file pointing at a dead PID" do
      key = Ezagent.URI.system("feishu", "ws")
      path = PidFile.file_path(@plugin, key)
      # Deliberately-dead large pid; start time bogus.
      File.write!(path, "99998\n0\n#{URI.to_string(key)}\n")

      assert :ok = OrphanReaper.reap(@plugin)
      refute File.exists?(path)
    end

    test "removes a pid file whose start_seconds mismatch (PID recycle) WITHOUT signalling" do
      key = Ezagent.URI.system("feishu", "ws")
      own_pid = String.to_integer(System.pid())
      path = PidFile.file_path(@plugin, key)
      # Our own (live) pid but a wrong stored start → recycled → rm, no kill.
      File.write!(path, "#{own_pid}\n1\n#{URI.to_string(key)}\n")

      assert :ok = OrphanReaper.reap(@plugin)
      refute File.exists?(path)
      # We (the BEAM) are still alive — proof no signal was sent.
      assert Process.alive?(self())
    end
  end

  describe "reap/1 — live matching orphan" do
    @tag :slow
    test "kills the live os_pid + deletes the file when start matches", ctx do
      os_pid = spawn_sleep(ctx)
      assert os_alive?(os_pid), "sleep #{os_pid} should be alive before reap"

      key = Ezagent.URI.system("feishu", "ws")
      # Capture the REAL start time the reaper will re-read at sweep time.
      start = PidFile.process_start_seconds(os_pid)
      assert is_integer(start)
      path = PidFile.file_path(@plugin, key)
      File.write!(path, "#{os_pid}\n#{start}\n#{URI.to_string(key)}\n")

      assert :ok = OrphanReaper.reap(@plugin)
      refute File.exists?(path)

      assert eventually_dead?(os_pid, 10_000),
             "orphan sleep #{os_pid} survived reap — it was not signalled"
    end

    @tag :slow
    test "a start-mismatched entry leaves the live os_pid UNSIGNALLED", ctx do
      os_pid = spawn_sleep(ctx)
      assert os_alive?(os_pid)

      key = Ezagent.URI.system("feishu", "ws")
      path = PidFile.file_path(@plugin, key)
      # Stored start deliberately wrong (1) → reaper sees a recycled pid →
      # removes the file but must NOT signal the (different) live process.
      File.write!(path, "#{os_pid}\n1\n#{URI.to_string(key)}\n")

      assert :ok = OrphanReaper.reap(@plugin)
      refute File.exists?(path)

      # Give any (erroneous) signal time to land, then assert still alive.
      Process.sleep(500)
      assert os_alive?(os_pid), "live sleep #{os_pid} was wrongly signalled on a recycle mismatch"
    end
  end
end
