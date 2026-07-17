defmodule Ezagent.Runtime.OsProcessTest do
  @moduledoc """
  Tests for `Ezagent.Runtime.OsProcess`.

  The `@tag :slow` orphan-proof tests run real OS processes and poll `ps`.
  They MUST pass (this repo does NOT exclude :slow; confirmed in SPEC §6).
  """

  use ExUnit.Case, async: false

  alias Ezagent.Runtime.OsProcess

  # Helper: check if an OS pid is still alive
  defp os_alive?(pid) when is_integer(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # Poll until the OS pid disappears or timeout_ms elapses
  defp eventually_dead?(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if System.monotonic_time(:millisecond) > deadline do
        :timeout
      else
        if os_alive?(os_pid), do: :alive, else: :dead
      end
    end)
    |> Enum.reduce_while(nil, fn
      :dead, _ ->
        {:halt, true}

      :timeout, _ ->
        {:halt, false}

      :alive, _ ->
        Process.sleep(200)
        {:cont, nil}
    end)
  end

  # ---------------------------------------------------------------------------
  # Step 4: subtree reap test (grandchild dies on stop)
  # ---------------------------------------------------------------------------

  @tag :slow
  test "stop/1 reaps the whole subtree — grandchild os_pid dies, not just the direct child" do
    # Trap exits so exec_pid exit doesn't crash the test process
    Process.flag(:trap_exit, true)

    {:ok, %{exec_pid: ep, os_pid: parent}} =
      OsProcess.spawn(
        ["/bin/sh", "-c", "sleep 300 & echo GRANDCHILD=$!; wait"],
        cd: System.tmp_dir!()
      )

    grandchild =
      receive do
        {:stdout, ^parent, b} ->
          data = IO.iodata_to_binary(b)
          [_, g] = Regex.run(~r/GRANDCHILD=(\d+)/, data)
          String.to_integer(g)
      after
        5_000 -> flunk("no grandchild pid received within 5s")
      end

    assert os_alive?(parent), "parent #{parent} should be alive before stop"
    assert os_alive?(grandchild), "grandchild #{grandchild} should be alive before stop"

    :ok = OsProcess.stop(ep)

    assert eventually_dead?(grandchild, 10_000),
           "grandchild #{grandchild} was orphaned — group-kill did not reap it"
  end

  # ---------------------------------------------------------------------------
  # Step 5: owner-death test (run_link reaps child on brutal owner kill)
  # ---------------------------------------------------------------------------

  @tag :slow
  test "child OS process dies when owner is killed with Process.exit/2 :kill" do
    test_pid = self()

    # The helper spawns via OsProcess (so run_link links helper↔exec_pid↔child)
    # We monitor (not link) the helper so our kill doesn't propagate back to us
    helper =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        case OsProcess.spawn(["/bin/sleep", "300"], cd: System.tmp_dir!()) do
          {:ok, %{os_pid: os_pid}} ->
            send(test_pid, {:os_pid, os_pid})
            # stay alive until killed
            receive do
              _ -> :ok
            end

          {:error, reason} ->
            send(test_pid, {:spawn_error, reason})
        end
      end)

    ref = Process.monitor(helper)

    os_pid =
      receive do
        {:os_pid, pid} -> pid
        {:spawn_error, reason} -> flunk("OsProcess.spawn failed: #{inspect(reason)}")
      after
        5_000 -> flunk("helper did not report os_pid within 5s")
      end

    assert os_alive?(os_pid), "OS child #{os_pid} should be alive before kill"

    # Brutally kill the owner — run_link should propagate to child
    Process.exit(helper, :kill)

    # Wait for helper to actually die
    assert_receive {:DOWN, ^ref, :process, ^helper, :killed}, 2_000

    assert eventually_dead?(os_pid, 10_000),
           "child #{os_pid} survived owner kill — run_link did not reap it"
  end

  # ---------------------------------------------------------------------------
  # Step 6b: clean-exit (status-0) test — exit reason is :normal
  # ---------------------------------------------------------------------------

  test "child exit 0 delivers {:EXIT, exec_pid, :normal} to trapping owner" do
    Process.flag(:trap_exit, true)

    {:ok, %{exec_pid: exec_pid}} =
      OsProcess.spawn(["/bin/sh", "-c", "exit 0"], cd: System.tmp_dir!())

    assert_receive {:EXIT, ^exec_pid, :normal}, 3_000
  end

  # ---------------------------------------------------------------------------
  # Step 7: pid-file write + cleanup
  # ---------------------------------------------------------------------------

  describe "pid_file opts" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "ezagent-ospid-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      prev_home = System.get_env("EZAGENT_HOME")
      prev_profile = System.get_env("EZAGENT_PROFILE")
      System.put_env("EZAGENT_HOME", tmp)
      System.put_env("EZAGENT_PROFILE", "osprocess-test")

      on_exit(fn ->
        if prev_home,
          do: System.put_env("EZAGENT_HOME", prev_home),
          else: System.delete_env("EZAGENT_HOME")

        if prev_profile,
          do: System.put_env("EZAGENT_PROFILE", prev_profile),
          else: System.delete_env("EZAGENT_PROFILE")

        File.rm_rf!(tmp)
      end)

      agent_uri = Ezagent.URI.agent("test-workspace", "test-agent")
      {:ok, tmp: tmp, agent_uri: agent_uri}
    end

    test "spawn with pid_file writes the pid file", %{agent_uri: agent_uri} do
      Process.flag(:trap_exit, true)

      plugin = "t"

      {:ok, %{exec_pid: ep, os_pid: os_pid}} =
        OsProcess.spawn(
          ["/bin/sleep", "60"],
          cd: System.tmp_dir!(),
          pid_file: {plugin, agent_uri}
        )

      path = Ezagent.Runtime.PidFile.file_path(plugin, agent_uri)
      assert File.exists?(path), "pid file should exist after spawn"
      contents = File.read!(path)
      assert String.starts_with?(contents, Integer.to_string(os_pid))

      # Clean up
      :ok = OsProcess.stop(ep)
    end

    test "cleanup_pid_file removes the pid file", %{agent_uri: agent_uri} do
      Process.flag(:trap_exit, true)

      plugin = "t"

      {:ok, %{exec_pid: ep}} =
        OsProcess.spawn(
          ["/bin/sleep", "60"],
          cd: System.tmp_dir!(),
          pid_file: {plugin, agent_uri}
        )

      path = Ezagent.Runtime.PidFile.file_path(plugin, agent_uri)
      assert File.exists?(path)

      :ok = OsProcess.cleanup_pid_file(plugin, agent_uri)
      refute File.exists?(path), "pid file should be removed by cleanup_pid_file"

      :ok = OsProcess.stop(ep)
    end
  end

  # ---------------------------------------------------------------------------
  # Basic interface tests (fast, non-slow)
  # ---------------------------------------------------------------------------

  describe "stop/1" do
    test "stop(nil) is a no-op" do
      assert :ok = OsProcess.stop(nil)
    end
  end

  describe "send/2" do
    test "send writes stdin to the process" do
      Process.flag(:trap_exit, true)

      {:ok, %{exec_pid: ep, os_pid: os_pid}} =
        OsProcess.spawn(["/bin/cat"], cd: System.tmp_dir!())

      :ok = OsProcess.send(ep, "hello\n")

      assert_receive {:stdout, ^os_pid, data}, 2_000
      assert IO.iodata_to_binary(data) =~ "hello"

      :ok = OsProcess.stop(ep)
    end
  end

  test "clear_env starts the child from only the explicitly supplied environment" do
    Process.flag(:trap_exit, true)
    previous = System.get_env("EZAGENT_OSPROCESS_SECRET")
    System.put_env("EZAGENT_OSPROCESS_SECRET", "must-not-cross-boundary")

    on_exit(fn ->
      if previous,
        do: System.put_env("EZAGENT_OSPROCESS_SECRET", previous),
        else: System.delete_env("EZAGENT_OSPROCESS_SECRET")
    end)

    {:ok, %{exec_pid: exec_pid, os_pid: os_pid}} =
      OsProcess.spawn(["/usr/bin/env"],
        cd: System.tmp_dir!(),
        clear_env: true,
        env: %{"ONLY_THIS" => "present"}
      )

    assert_receive {:stdout, ^os_pid, output}, 2_000
    assert IO.iodata_to_binary(output) == "ONLY_THIS=present\n"
    assert_receive {:EXIT, ^exec_pid, :normal}, 2_000
  end
end
