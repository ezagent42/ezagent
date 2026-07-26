defmodule EzagentPluginCodex.CodexSidecarErlexecTest do
  @moduledoc """
  TDD tests for the AppServer + BridgeSidecar migration from native
  `Port.open` to `Ezagent.Runtime.OsProcess` (erlexec).

  SPEC `docs/superpowers/specs/2026-06-25-sidecar-erlexec-runtime.md` §4.
  Task 4 brief: `.superpowers/sdd/task-4-brief.md`.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Runtime.Resolver
  alias EzagentPluginCodex.AppServer
  alias EzagentPluginCodex.BridgeSidecar

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp test_uri(name) do
    URI.new!("entity://system/agent/codex_#{name}")
  end

  # Ensure the sidecar is stopped after each test so registry doesn't collide.
  defp ensure_stopped(module, agent_uri) do
    module.stop(agent_uri)
    # Give DynamicSupervisor a moment to complete the termination.
    :timer.sleep(50)
  end

  # ---------------------------------------------------------------------------
  # Step 1: test_mode — alive?/1 true after start/2 in :test env
  # ---------------------------------------------------------------------------

  describe "AppServer test_mode (no real codex binary needed)" do
    test "alive?/1 is true after start/2 in :test env" do
      agent_uri = test_uri("app-server-alive")

      on_exit(fn -> ensure_stopped(AppServer, agent_uri) end)

      # test_mode defaults to true in :test env via @compile_env.
      # We confirm the no-spawn short-circuit holds:
      # start/2 MUST succeed without a codex binary on PATH.
      assert {:ok, _pid} =
               AppServer.start(agent_uri, %{
                 cwd: System.tmp_dir!(),
                 socket_path: "/tmp/codex_test.sock"
               })

      assert AppServer.alive?(agent_uri)
    end

    test "alive?/1 is false before start/2" do
      agent_uri = test_uri("app-server-not-started")
      refute AppServer.alive?(agent_uri)
    end

    test "stop/1 brings alive?/1 back to false" do
      agent_uri = test_uri("app-server-stop")

      assert {:ok, _pid} =
               AppServer.start(agent_uri, %{
                 cwd: System.tmp_dir!(),
                 socket_path: "/tmp/codex_test_stop.sock"
               })

      assert AppServer.alive?(agent_uri)

      AppServer.stop(agent_uri)
      :timer.sleep(50)
      refute AppServer.alive?(agent_uri)
    end

    test "recent_output/1 returns empty string in test_mode" do
      agent_uri = test_uri("app-server-output")

      on_exit(fn -> ensure_stopped(AppServer, agent_uri) end)

      assert {:ok, _pid} =
               AppServer.start(agent_uri, %{
                 cwd: System.tmp_dir!(),
                 socket_path: "/tmp/codex_test_output.sock"
               })

      assert AppServer.recent_output(agent_uri) == ""
    end
  end

  describe "AppServer resolver seam (V5 A1b)" do
    test "registered under the :via key; Resolver.alive?/call reach it; os_pid served by call" do
      agent_uri = test_uri("app-server-seam")

      on_exit(fn -> ensure_stopped(AppServer, agent_uri) end)

      assert {:ok, _pid} =
               AppServer.start(agent_uri, %{
                 cwd: System.tmp_dir!(),
                 socket_path: "/tmp/codex_test_seam.sock"
               })

      key = AppServer.resolver_key(agent_uri)
      assert key == {agent_uri, :ezagent_plugin_codex, :codex_app}

      # Resolvable through the seam (pid-free liveness + calls).
      assert Resolver.alive?(key)
      assert Resolver.whereis(key) == :ok
      assert {:ok, ""} = Resolver.call(key, :recent_output, 500)

      # test_mode: no OS child — os_pid served by handle_call(:os_pid)
      # through the seam, never `:sys.get_state/2`.
      assert {:ok, nil} = Resolver.call(key, :os_pid, 500)
      assert AppServer.os_pid(agent_uri) == nil

      # stop/1 goes through Resolver.terminate_child — the key leaves the seam.
      AppServer.stop(agent_uri)
      :timer.sleep(50)
      refute Resolver.alive?(key)
    end
  end

  describe "AppServer readiness" do
    test "wait_until_ready/3 fails fast when the process never creates its socket" do
      agent_uri = test_uri("app-server-no-socket-#{System.unique_integer([:positive])}")

      stub_path =
        Path.join(System.tmp_dir!(), "stub_codex_no_socket_#{System.unique_integer([:positive])}")

      socket_path =
        Path.join(System.tmp_dir!(), "codex_no_socket_#{System.unique_integer([:positive])}.sock")

      File.write!(stub_path, "#!/bin/sh\necho no-socket\nsleep 2\n")
      File.chmod!(stub_path, 0o755)

      on_exit(fn ->
        ensure_stopped(AppServer, agent_uri)
        File.rm(stub_path)
        File.rm(socket_path)
      end)

      assert {:ok, _pid} =
               AppServer.start(agent_uri, %{
                 cwd: System.tmp_dir!(),
                 socket_path: socket_path,
                 codex_path: stub_path,
                 test_mode: false
               })

      assert {:error, {:codex_app_server_socket_timeout, ^socket_path, _output}} =
               AppServer.wait_until_ready(agent_uri, socket_path, 200)
    end
  end

  describe "BridgeSidecar test_mode (no real python/uv binary needed)" do
    test "alive?/1 is true after start/2 in :test env" do
      agent_uri = test_uri("bridge-alive")

      on_exit(fn -> ensure_stopped(BridgeSidecar, agent_uri) end)

      # BridgeSidecar test_mode also skips spawn.
      assert {:ok, _pid} = BridgeSidecar.start(agent_uri, %{})
      assert BridgeSidecar.alive?(agent_uri)
    end

    test "recent_output/1 returns empty string in test_mode" do
      agent_uri = test_uri("bridge-output")

      on_exit(fn -> ensure_stopped(BridgeSidecar, agent_uri) end)

      assert {:ok, _pid} = BridgeSidecar.start(agent_uri, %{})
      assert BridgeSidecar.recent_output(agent_uri) == ""
    end
  end

  describe "BridgeSidecar resolver seam (V5 A1b)" do
    test "registered under the :via key; Resolver.alive?/call reach it; stop terminates via seam" do
      agent_uri = test_uri("bridge-seam")

      on_exit(fn -> ensure_stopped(BridgeSidecar, agent_uri) end)

      assert {:ok, _pid} = BridgeSidecar.start(agent_uri, %{})

      key = BridgeSidecar.resolver_key(agent_uri)
      assert key == {agent_uri, :ezagent_plugin_codex, :codex_bridge}

      # Resolvable through the seam (pid-free liveness + calls).
      assert Resolver.alive?(key)
      assert Resolver.whereis(key) == :ok
      assert {:ok, ""} = Resolver.call(key, :recent_output, 500)

      # stop/1 goes through Resolver.terminate_child — the key leaves the seam.
      BridgeSidecar.stop(agent_uri)
      :timer.sleep(50)
      refute Resolver.alive?(key)
    end
  end

  # ---------------------------------------------------------------------------
  # Step 4: orphan proof @tag :slow
  # Codex binary likely absent in CI; we use AppServer with a stub executable
  # and test_mode: false to exercise the real OsProcess spawn path.
  # ---------------------------------------------------------------------------

  describe "AppServer orphan/stop proof" do
    @tag :slow
    test "OS process is dead within 10s of AppServer.stop/1" do
      agent_uri = test_uri("orphan-proof-#{System.unique_integer([:positive])}")

      # Write a stub "codex" that immediately exec-sleeps so we get a long-lived pid.
      stub_path = Path.join(System.tmp_dir!(), "stub_codex_#{System.unique_integer([:positive])}")

      File.write!(stub_path, "#!/bin/sh\nexec sleep 300\n")
      File.chmod!(stub_path, 0o755)

      socket_path =
        Path.join(System.tmp_dir!(), "codex_test_#{System.unique_integer([:positive])}.sock")

      cwd = System.tmp_dir!()

      on_exit(fn ->
        ensure_stopped(AppServer, agent_uri)
        File.rm(stub_path)
        File.rm(socket_path)
      end)

      # Force test_mode: false to exercise the real spawn path.
      assert {:ok, _pid} =
               AppServer.start(agent_uri, %{
                 cwd: cwd,
                 socket_path: socket_path,
                 codex_path: stub_path,
                 test_mode: false
               })

      assert AppServer.alive?(agent_uri)

      # V5 A1b: os_pid comes from the explicit seam query
      # (`handle_call(:os_pid)` via `Resolver.call/3`), never
      # `:sys.get_state/2`.
      os_pid = AppServer.os_pid(agent_uri)
      assert is_integer(os_pid) and os_pid > 0

      # Stop the sidecar (goes through OsProcess.stop → :exec.stop).
      AppServer.stop(agent_uri)

      # Poll for the OS process to die (max 10s).
      result =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          case System.cmd("ps", ["-p", Integer.to_string(os_pid)], stderr_to_stdout: true) do
            {_, 0} ->
              :timer.sleep(500)
              {:cont, :still_alive}

            {_, _} ->
              {:halt, :gone}
          end
        end)

      assert result == :gone, "OS process #{os_pid} still alive after AppServer.stop/1"
    end

    @tag :slow
    test "OS process is dead within 10s of owner crash (:kill)" do
      agent_uri = test_uri("owner-kill-#{System.unique_integer([:positive])}")

      stub_path =
        Path.join(System.tmp_dir!(), "stub_codex_kill_#{System.unique_integer([:positive])}")

      File.write!(stub_path, "#!/bin/sh\nexec sleep 300\n")
      File.chmod!(stub_path, 0o755)

      socket_path =
        Path.join(System.tmp_dir!(), "codex_kill_#{System.unique_integer([:positive])}.sock")

      cwd = System.tmp_dir!()

      on_exit(fn ->
        ensure_stopped(AppServer, agent_uri)
        File.rm(stub_path)
        File.rm(socket_path)
      end)

      assert {:ok, gs_pid} =
               AppServer.start(agent_uri, %{
                 cwd: cwd,
                 socket_path: socket_path,
                 codex_path: stub_path,
                 test_mode: false
               })

      # V5 A1b: os_pid via the explicit seam query; the GenServer pid itself
      # comes from the plugin's own spawn return (no registry lookup).
      os_pid = AppServer.os_pid(agent_uri)
      assert is_integer(os_pid) and os_pid > 0

      # Monitor so we can wait for the GenServer to die without needing a link.
      ref = Process.monitor(gs_pid)

      # Kill the GenServer owner — run_link should reap the OS process.
      Process.exit(gs_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^gs_pid, :killed}, 2_000

      # Poll for the OS process to die (max 10s).
      result =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          case System.cmd("ps", ["-p", Integer.to_string(os_pid)], stderr_to_stdout: true) do
            {_, 0} ->
              :timer.sleep(500)
              {:cont, :still_alive}

            {_, _} ->
              {:halt, :gone}
          end
        end)

      assert result == :gone, "OS process #{os_pid} still alive after owner :kill"
    end
  end
end
