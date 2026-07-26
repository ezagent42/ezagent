defmodule EzagentPluginCc.SdkSidecarErlexecTest do
  @moduledoc """
  Proves SdkSidecar works over erlexec (OsProcess):

  1. JSON round-trip — start SdkSidecar against a deterministic stub worker
     that echoes one JSON-line reply; assert query/3 → {:ok, %{content: …}}.
  2. Orphan proof — capture worker os_pid, stop sidecar, poll `ps -p` dead
     (NEVER pkill). @tag :slow — runs under `mix test` (no :slow exclude).

  DoD proof: JSON-line protocol over erlexec. NOT a full-SDK e2e.
  """

  use ExUnit.Case, async: false

  require Logger

  alias EzagentPluginCc.SdkSidecar

  @moduletag :slow

  # Minimal stub worker script: reads one JSON line from stdin,
  # echoes a valid reply using the same "id" field, then exits.
  # Wrapped in a heredoc so no external file is needed.
  @stub_script """
  import sys, json
  line = sys.stdin.readline()
  frame = json.loads(line.strip())
  reply = {"id": frame["id"], "ok": True, "content": "pong", "session_id": "stub-session"}
  print(json.dumps(reply), flush=True)
  sys.stdout.flush()
  """

  setup do
    # Deterministic agent URI for isolation.
    idx = System.unique_integer([:positive, :monotonic])
    agent_uri = Ezagent.URI.new!("entity://test-ws/agent/sdk-sidecar-test-#{idx}")

    # Write stub script to a temp file.
    script_path = Path.join(System.tmp_dir!(), "sdk_stub_#{idx}.py")
    File.write!(script_path, @stub_script)

    on_exit(fn ->
      # Ensure the sidecar is stopped (idempotent).
      _ = SdkSidecar.stop(agent_uri)
      File.rm(script_path)
    end)

    {:ok, agent_uri: agent_uri, script_path: script_path}
  end

  defp find_python3 do
    # Prefer python3, fall back to python.
    System.find_executable("python3") || System.find_executable("python") ||
      raise "python3 not found in PATH — required for SdkSidecar stub test"
  end

  defp start_sidecar(agent_uri, script_path) do
    cwd = System.tmp_dir!()

    params = %{
      cwd: cwd,
      config_dir: cwd,
      # Override the runner and script to use our stub directly.
      python_path: find_python3(),
      sdk_worker_path: script_path
    }

    {:ok, _pid} = SdkSidecar.start(agent_uri, params)
    :ok
  end

  # ─── Step 1: JSON round-trip ───────────────────────────────────────────────

  # Task A (#1323 落 main) — live-e2e-found gap: the PTY flavor's cwd is
  # created only as a SIDE EFFECT of `McpConfigWriter.write_with_token!`
  # (cwd-level .mcp.json write); the headless path never calls the writer, so
  # on a fresh host the sidecar crash-looped with
  # "Cannot chdir to '~/.ezagent/<role>'". The sidecar must ensure its own cwd.
  describe "cwd materialization" do
    test "sidecar creates a nonexistent cwd instead of crash-looping", ctx do
      cwd =
        Path.join(
          System.tmp_dir!(),
          "sdk-sidecar-fresh-cwd-#{System.unique_integer([:positive])}"
        )

      refute File.dir?(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      params = %{
        cwd: cwd,
        config_dir: cwd,
        python_path: find_python3(),
        sdk_worker_path: ctx.script_path
      }

      assert {:ok, _pid} = SdkSidecar.start(ctx.agent_uri, params)
      assert File.dir?(cwd)

      assert {:ok, %{content: "pong"}} =
               SdkSidecar.query(ctx.agent_uri, "ping", timeout: 15_000)
    end
  end

  describe "JSON round-trip (erlexec transport)" do
    test "query/3 returns {:ok, %{content: 'pong'}} via stub worker", ctx do
      :ok = start_sidecar(ctx.agent_uri, ctx.script_path)

      result = SdkSidecar.query(ctx.agent_uri, "hello", timeout: 5_000)

      assert {:ok, %{content: "pong"}} = result
    end
  end

  describe "SdkSidecar resolver seam (V5 A1b)" do
    test "registered under the :via key; Resolver.alive?/call reach it; stop terminates via seam",
         ctx do
      :ok = start_sidecar(ctx.agent_uri, ctx.script_path)

      key = SdkSidecar.resolver_key(ctx.agent_uri)
      assert key == {ctx.agent_uri, :ezagent_plugin_cc, :cc_sdk}

      # Resolvable through the seam (pid-free liveness + calls).
      assert Ezagent.Runtime.Resolver.alive?(key)
      assert Ezagent.Runtime.Resolver.whereis(key) == :ok

      assert {:ok, {:ok, %{content: "pong"}}} =
               Ezagent.Runtime.Resolver.call(key, {:query, "ping", nil}, 5_000)

      # stop/1 goes through Resolver.terminate_child — the key leaves the
      # seam on the Registry's async DOWN-cleanup (poll briefly).
      :ok = SdkSidecar.stop(ctx.agent_uri)
      assert await_seam_gone(key)
    end
  end

  defp await_seam_gone(key, attempts \\ 100)
  defp await_seam_gone(_key, 0), do: false

  defp await_seam_gone(key, attempts) do
    if Ezagent.Runtime.Resolver.alive?(key) do
      Process.sleep(10)
      await_seam_gone(key, attempts - 1)
    else
      true
    end
  end

  # ─── Step 3: Orphan proof ──────────────────────────────────────────────────

  describe "orphan proof (os_pid dies on stop)" do
    test "OS worker process is reaped when sidecar stops", ctx do
      :ok = start_sidecar(ctx.agent_uri, ctx.script_path)

      # Round-trip first so the sidecar is definitely alive.
      # The stub exits after one reply, so we need a long-lived stub.
      # For orphan proof, we use a "sleep" stub instead:
      # Override the script with a long-lived version.
      long_script = """
      import sys, json, time
      while True:
          line = sys.stdin.readline()
          if not line:
              break
          frame = json.loads(line.strip())
          reply = {"id": frame["id"], "ok": True, "content": "pong", "session_id": "stub"}
          print(json.dumps(reply), flush=True)
      """

      # Stop the one-shot sidecar first.
      :ok = SdkSidecar.stop(ctx.agent_uri)
      # Wait briefly for cleanup.
      Process.sleep(100)

      # Start a long-lived stub.
      idx = System.unique_integer([:positive, :monotonic])
      long_script_path = Path.join(System.tmp_dir!(), "sdk_stub_long_#{idx}.py")
      File.write!(long_script_path, long_script)

      on_exit(fn -> File.rm(long_script_path) end)

      idx2 = System.unique_integer([:positive, :monotonic])
      agent_uri2 = Ezagent.URI.new!("entity://test-ws/agent/sdk-orphan-test-#{idx2}")

      on_exit(fn -> SdkSidecar.stop(agent_uri2) end)

      cwd = System.tmp_dir!()

      params = %{
        cwd: cwd,
        config_dir: cwd,
        python_path: find_python3(),
        sdk_worker_path: long_script_path
      }

      {:ok, pid} = SdkSidecar.start(agent_uri2, params)

      # Send a query to confirm it's alive.
      assert {:ok, %{content: "pong"}} = SdkSidecar.query(agent_uri2, "probe", timeout: 5_000)

      # Capture the os_pid via GenServer state.
      %{os_pid: os_pid} = :sys.get_state(pid)
      assert is_integer(os_pid) and os_pid > 0

      # Stop the sidecar — this triggers OsProcess.stop(exec_pid) → kill_group.
      :ok = SdkSidecar.stop(agent_uri2)

      # Poll until the OS process is dead (≤ 10 s).
      result =
        Enum.reduce_while(1..40, nil, fn _, _ ->
          case System.cmd("ps", ["-p", Integer.to_string(os_pid)], stderr_to_stdout: true) do
            {_, 0} ->
              Process.sleep(250)
              {:cont, :still_alive}

            {_, _} ->
              {:halt, :gone}
          end
        end)

      assert result == :gone,
             "OS worker pid #{os_pid} still alive 10 s after SdkSidecar.stop/1 — orphan leak"
    end
  end
end
