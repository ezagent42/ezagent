defmodule Ezagent.PluginCc.DevChannelsConfirmTest do
  @moduledoc """
  Integration test: verify PtyServer auto-confirms claude's
  `--dangerously-load-development-channels` dialog by detecting the
  prompt text in PTY stdout and writing "1\\r" to stdin.

  Uses a FAKE shell script (`test/fixtures/mock_claude_prompt.sh`)
  that emits the same dialog text claude does (interleaved with ANSI
  cursor-positioning escapes that the real binary uses), waits for
  stdin to contain "1\\r", then writes "CONFIRMED" + exits.

  If PtyServer's auto-confirm logic works, the mock script sees "1\\r"
  → exits cleanly → DOWN message arrives. If broken, the script
  times out (sleep 10 then exit 1) → PtyServer DOWN with non-zero
  exit code.

  This test runs only if `:exec` is available + `bash` is on PATH.
  """

  use ExUnit.Case, async: false
  require Logger

  alias Ezagent.Domain.Pty.Server, as: PtyServer

  @moduletag :requires_exec

  setup_all do
    # Ensure erlexec is started
    case :application.ensure_all_started(:erlexec) do
      {:ok, _} -> :ok
      {:error, reason} -> {:skip, "erlexec unavailable: #{inspect(reason)}"}
    end

    :ok
  end

  setup do
    fixture_dir =
      Path.join([
        File.cwd!(),
        "apps",
        "ezagent_plugin_cc",
        "test",
        "fixtures"
      ])

    File.mkdir_p!(fixture_dir)

    script_path = Path.join(fixture_dir, "mock_claude_prompt.sh")
    write_mock_script!(script_path)
    File.chmod!(script_path, 0o755)

    on_exit(fn ->
      File.rm(script_path)
    end)

    {:ok, fixture_dir: fixture_dir, script_path: script_path}
  end

  defp write_mock_script!(path) do
    # Simulate claude's prompt + wait for "1\r" + echo CONFIRMED + exit
    File.write!(path, """
    #!/usr/bin/env bash
    set -e
    # Emit the dialog text — interleave a cursor-forward CSI between
    # words to mimic claude's actual layout (which is what AnsiStrip
    # collapses to spaces).
    printf 'Loading\\e[1Cdevelopment\\e[1Cchannels\\n'
    printf 'Press 1: I am using this for local development\\n'
    printf '> '

    # Wait for "1" + newline via read with 10s timeout
    if IFS= read -t 10 -r line; then
      if [[ "$line" == "1" ]]; then
        echo "CONFIRMED"
        exit 0
      fi
      echo "WRONG-INPUT:$line"
      exit 2
    fi
    echo "TIMEOUT"
    exit 1
    """)
  end

  test "auto-confirms prompt when PtyServer sees both signature strings", %{
    fixture_dir: fixture_dir,
    script_path: script_path
  } do
    # PtyServer spawns `claude` directly via :exec.run. Test uses
    # cmd_override to inject the mock script instead of needing a real
    # claude binary.
    test_cwd = Path.join(fixture_dir, "test_cwd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_cwd)

    on_exit(fn -> File.rm_rf(test_cwd) end)

    # Trap exit so the test process survives the linked GenServer's
    # stop. Otherwise PtyServer's `{:stop, {:child_exited, ...}}`
    # propagates as :EXIT and kills the test.
    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PtyServer.start_link(%{
        agent_uri: URI.parse("entity://agent/team-alpha/test_e2e-test"),
        cwd: test_cwd,
        # Force real-spawn even in test env
        test_mode: false,
        cmd_override: "bash #{script_path}"
      })

    ref = Process.monitor(pid)

    # Wait for the child process to exit (either CONFIRMED → exit 0,
    # TIMEOUT → exit 1, or WRONG-INPUT → exit 2).
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        # Success markers (erlexec wraps child exit differently across
        # versions): :normal | {:exit_status, 0} | {:child_exited,
        # :normal} | {:child_exited, {:exit_status, 0}}
        case reason do
          :normal -> :ok
          {:exit_status, 0} -> :ok
          {:child_exited, :normal} -> :ok
          {:child_exited, {:exit_status, 0}} -> :ok
          other -> flunk("PtyServer exited with #{inspect(other)} — expected normal/0 (CONFIRMED)")
        end
    after
      15_000 -> flunk("PtyServer didn't exit within 15s — auto-confirm likely broken")
    end
  end
end
