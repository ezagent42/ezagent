defmodule EzagentPluginFeishu.WsClientErlexecTest do
  @moduledoc """
  Task 5 (subtask B) — `EzagentPluginFeishu.WsClient` migrated from native
  `Port.open` to `Ezagent.Runtime.OsProcess` (erlexec).

  Proves the two DoD properties for the feishu node sidecar:

    1. **No orphans (subtree reap, precise ownership).** When the owning
       `WsClient` GenServer is brutally killed, the node sidecar AND a worker
       grandchild it forked both die — via `run_link` (owner-death) +
       `kill_group` ({group,0}+:kill_group). Captures the EXACT grandchild
       os_pid and polls `ps -p` (never `pkill`).
    2. **Boot reaper.** `init/1` reaps a planted prior-incarnation `feishu-ws`
       pid file.

  feishu is NOT started at test boot (`maybe_ws_client_spec/0` returns nil in
  `:test`), so each test owns the WsClient lifecycle via `start_supervised!/1`
  (`restart: :temporary` so a brutal kill does not respawn). A deterministic
  forking node stub (set via the `:ws_sidecar_path` test seam) stands in for
  the lark SDK main.js so a grandchild exists to capture. Tagged `:slow` (real
  OS processes); this repo runs `:slow` under `mix test`.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Runtime.PidFile

  @moduletag :slow

  # A node stub that forks a real grandchild (`sleep 300`) and stays alive.
  @node_stub """
  const { spawn } = require('child_process');
  const child = spawn('sleep', ['300'], { stdio: 'ignore' });
  process.stdout.write('GRANDCHILD=' + child.pid + '\\n');
  setInterval(() => {}, 1000);
  """

  setup do
    # Per-test EZAGENT_HOME so credential + pid-file dirs are isolated.
    home = Path.join(System.tmp_dir!(), "feishu_ws_erlexec_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([home, "default", "credentials"]))

    File.write!(
      Path.join([home, "default", "credentials", "feishu.yaml"]),
      "app_id: cli_test_app_id\napp_secret: test_secret_value\n"
    )

    node = System.find_executable("node")

    if node do
      stub = Path.join(home, "node_stub.js")
      File.write!(stub, @node_stub)
      Application.put_env(:ezagent_plugin_feishu, :ws_sidecar_path, stub)
    end

    prev_home = System.get_env("EZAGENT_HOME")
    prev_ws = System.get_env("EZAGENT_FEISHU_WS")
    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_feishu, :ws_sidecar_path)
      Application.delete_env(:ezagent_plugin_feishu, :reap_orphans_on_boot)
      restore_env("EZAGENT_HOME", prev_home)
      restore_env("EZAGENT_FEISHU_WS", prev_ws)
      File.rm_rf(home)
    end)

    {:ok, node: node}
  end

  test "killing WsClient reaps the node sidecar AND its forked grandchild (run_link + kill_group)",
       %{node: node} do
    if node do
      pid = start_supervised!(EzagentPluginFeishu.WsClient, restart: :temporary)

      # Wait for the deferred :open_sidecar spawn to land an os_pid.
      node_os_pid = wait_for(fn -> :sys.get_state(pid).os_pid end, 5_000)
      assert is_integer(node_os_pid)

      # The grandchild the node stub forked.
      grandchild = wait_for(fn -> child_pid_of(node_os_pid) end, 5_000)
      assert is_integer(grandchild), "node stub did not fork a grandchild to capture"
      assert os_alive?(node_os_pid) and os_alive?(grandchild)

      # Brutal owner kill (untrappable → terminate does NOT run; reaping rides
      # the run_link BEAM link + erlexec group-kill, NOT a graceful stop).
      Process.exit(pid, :kill)

      assert eventually_dead?(grandchild, 10_000),
             "grandchild #{grandchild} orphaned — kill_group did not reap the node subtree"

      assert eventually_dead?(node_os_pid, 10_000),
             "node sidecar #{node_os_pid} orphaned after owner kill"
    else
      # node absent — the kill_group subtree mechanism is also proven generically
      # by the Ezagent.Runtime.OsProcess unit test (Task 1). Nothing to assert here.
      :ok
    end
  end

  test "init/1 reaps a prior-incarnation feishu-ws pid file" do
    # Stay idle (no own sidecar spawn) so the only feishu-ws pid file is the
    # planted one — but STILL run the init reaper.
    System.put_env("EZAGENT_FEISHU_WS", "0")
    Application.put_env(:ezagent_plugin_feishu, :reap_orphans_on_boot, true)

    # Plant a stale pid file pointing at a real live process. No `:monitor`/
    # `:link`: the reaper's SIGTERM must not propagate an exit to this test
    # process, and we detect the orphan's death by polling OS liveness (below),
    # NOT by awaiting erlexec's `{:DOWN}` message. #108: DOWN delivery through
    # the shared `:exec` port + BEAM scheduler could blow the 10s
    # `assert_receive` backstop on a loaded CI runner (a flake); `ps`-polling —
    # the same pattern the sibling "killing WsClient" test uses un-flagged —
    # decouples death-detection from erlexec message scheduling.
    {:ok, _ep, stale_os_pid} = :exec.run([~c"/bin/sleep", ~c"300"], [])

    key = Ezagent.URI.system("feishu", "ws")
    :ok = PidFile.write("feishu-ws", key, stale_os_pid)
    assert os_alive?(stale_os_pid)

    # Booting WsClient runs the init reaper, which kills + removes the stale entry.
    _pid = start_supervised!(EzagentPluginFeishu.WsClient, restart: :temporary)

    # The init reaper SIGTERMs the planted orphan; poll real OS liveness (the
    # file's own `eventually_dead?/2`, same as the sibling "killing WsClient"
    # test) until it's gone. Deterministic and independent of erlexec's
    # DOWN-message scheduling — the #108 flake was the DOWN delivery blowing the
    # `assert_receive` backstop on a loaded runner, never the reap itself.
    assert eventually_dead?(stale_os_pid, 10_000),
           "init reaper did not reap the planted feishu-ws orphan #{stale_os_pid}"

    # The reaper's PidFile.remove runs synchronously inside init/1, so by the time
    # start_supervised! returned the stale entry is already gone.
    assert PidFile.enumerate("feishu-ws") == [],
           "init reaper did not remove the stale feishu-ws pid file"
  end

  # --- helpers -----------------------------------------------------------

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  defp wait_for(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          do_wait_for(fun, deadline)
        else
          nil
        end

      value ->
        value
    end
  end

  # First child OS pid of `parent` per `pgrep -P` (nil if none yet).
  defp child_pid_of(parent) do
    case System.cmd("pgrep", ["-P", Integer.to_string(parent)], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> List.first() |> parse_pid()

      _ ->
        nil
    end
  end

  defp parse_pid(nil), do: nil
  defp parse_pid(s), do: String.to_integer(String.trim(s))

  defp os_alive?(os_pid) do
    match?({_, 0}, System.cmd("ps", ["-p", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end

  defp eventually_dead?(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually_dead?(os_pid, deadline)
  end

  defp do_eventually_dead?(os_pid, deadline) do
    cond do
      not os_alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(200)
        do_eventually_dead?(os_pid, deadline)
    end
  end
end
