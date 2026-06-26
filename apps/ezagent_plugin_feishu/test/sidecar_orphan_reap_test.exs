defmodule EzagentPluginFeishu.SidecarOrphanReapTest do
  @moduledoc """
  Phase 7 PR 35 invariant — the Node sidecar exits when its parent BEAM dies,
  preventing orphan accumulation.

  ## Background

  `Ezagent.PluginFeishu.WsClient` spawns the Node sidecar via
  `Port.open({:spawn_executable, node_bin}, ...)`. Erlang `:spawn_executable`
  Ports do NOT propagate signals to the child when the BEAM exits — the OS
  reparents the Node process to PID 1 and it keeps running. Symptom (Phase 6
  PR 27): every phx.server restart leaks an orphan sidecar; multiple orphans
  race for Feishu inbound events, silently stealing messages.

  ## Fix — orphan reap via PARENT-PID POLL (2026-06-26, #1024)

  The original reap used `process.stdin.on('end', …)` + `process.stdin.resume()`.
  That was REPLACED: `process.stdin.resume()` puts Node in flowing mode and
  STARVES the Lark SDK's internal WSS event loop, so no `im.message.receive_v1`
  events are delivered (bisect-3, 2026-06-26). The sidecar now records its parent
  pid at boot (`const PARENT_PID = process.ppid`) and polls every 5s; when the
  parent dies the child is re-parented (`process.ppid !== PARENT_PID` / `=== 1`)
  and it `process.exit(0)`s so the WsClient GenServer can respawn it.

  ## Test strategy

  1. **Static check** — grep main.js for the parent-PID poll (likely regression:
     someone reintroduces `stdin.resume()` and re-breaks WSS, or drops the poll).
     ALSO asserts the ABSENCE of `stdin.resume()` — the specific #1024 regression.
  2. **Integration check** (`:slow`) — spawn the sidecar, close the Port so the
     BEAM stops being its parent, assert the Node pid dies within the poll window
     (~5s + margin) now that reap is parent-death-driven, not stdin-EOF.
  """

  use ExUnit.Case, async: true

  @sidecar_path Path.expand("../priv/ws_sidecar/main.js", __DIR__)

  test "sidecar main.js reaps via a parent-PID poll (NOT stdin.resume, which starves the Lark WSS loop)" do
    assert File.exists?(@sidecar_path),
           "sidecar main.js not found at #{@sidecar_path}; cannot test orphan reap"

    source = File.read!(@sidecar_path)

    assert source =~ ~r/process\.ppid/,
           "main.js does not reference process.ppid — the parent-PID orphan-reap poll is missing. " <>
             "Phase 6 PR 27 lesson: orphan sidecars steal Feishu inbound events."

    assert source =~ ~r/setInterval/,
           "main.js has no setInterval — the 5s parent-liveness poll is missing"

    assert source =~ ~r/process\.ppid\s*!==\s*PARENT_PID/ or source =~ ~r/process\.ppid\s*===\s*1/,
           "main.js does not check for parent death (process.ppid changed / === 1) — reap is broken"

    assert source =~ ~r/process\.exit/,
           "main.js never calls process.exit — the orphan would never be reaped"

    # The specific regression #1024 fixed: an ACTIVE stdin.resume() call starves
    # the Lark SDK WSS event loop (no inbound events). It must NOT come back.
    # (The moduledoc/comments legitimately MENTION it to explain the fix, so we
    # check only non-comment code lines.)
    code_only =
      source
      |> String.split("\n")
      |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("//")))
      |> Enum.join("\n")

    refute code_only =~ ~r/process\.stdin\.resume\(\)/,
           "main.js has an ACTIVE process.stdin.resume() call — this starves the Lark SDK WSS " <>
             "loop so no im.message.receive_v1 events are delivered (bisect-3, 2026-06-26). " <>
             "Reap must use the parent-PID poll, not stdin EOF."
  end

  @tag :slow
  @tag timeout: 30_000
  test "spawned sidecar exits within the poll window after its parent (the BEAM Port) dies (integration)" do
    node_bin = System.find_executable("node")
    if is_nil(node_bin), do: flunk("node binary not found in PATH — cannot run integration test")

    port =
      Port.open(
        {:spawn_executable, node_bin},
        [
          :binary,
          :exit_status,
          {:args, [@sidecar_path]},
          {:env,
           [
             {~c"FEISHU_APP_ID", ~c"test_app_id_orphan_reap"},
             {~c"FEISHU_APP_SECRET", ~c"test_app_secret_orphan_reap"}
           ]}
        ]
      )

    {:os_pid, node_pid} = Port.info(port, :os_pid)

    assert os_pid_alive?(node_pid),
           "sidecar pid #{node_pid} died before we could test parent-death reap"

    # Close the Port: the BEAM stops being the child's parent → node re-parents
    # to PID 1 → its 5s poll detects the ppid change → process.exit(0).
    Port.close(port)

    assert eventually_dead?(node_pid, 9_000),
           "sidecar pid #{node_pid} still alive ~9s after its parent died — the parent-PID " <>
             "poll (5s interval) did not reap it"
  end

  defp os_pid_alive?(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp eventually_dead?(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually_dead?(pid, deadline)
  end

  defp do_eventually_dead?(pid, deadline) do
    cond do
      not os_pid_alive?(pid) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true ->
        Process.sleep(500)
        do_eventually_dead?(pid, deadline)
    end
  end
end
