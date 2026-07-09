defmodule Ezagent.Domain.Pty.Server.SnapshotBufferTest do
  @moduledoc """
  Verify the ttyd-style initial-render helpers on `Ezagent.Domain.Pty.Server`:

  - `snapshot_buffer/2` returns the current pty_buffer for a live PtyServer,
    bounded to the requested byte cap
  - `snapshot_buffer/2` returns `:error` for an unknown agent_uri
  - `trigger_redraw/1` is a no-op for an agent without a live os_pid
    (test_mode), returns `:ok`

  We don't exercise the actual SIGWINCH delivery here — that requires
  a real PTY, which `:test_mode` deliberately avoids.

  Moved from `apps/ezagent_plugin_cc/test/ezagent/plugin_cc/snapshot_buffer_test.exs`
  to the new ezagent_domain_pty app per SPEC v1 (2026-05-21) §3.1.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty.Server, as: PtyServer

  setup do
    # Tests run under Mix.env() == :test, so PtyServer's test_mode
    # short-circuits the real :exec spawn. We can still get_state on
    # the GenServer to verify the snapshot path.
    agent_uri =
      URI.new!("entity://team-alpha/agent/test_snapshot-test-#{System.unique_integer([:positive])}")

    {:ok, pid} = Ezagent.Domain.Pty.start(agent_uri, %{cwd: "/tmp", test_mode: true})

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(EzagentDomainPty.Supervisor, pid)
      end
    end)

    {:ok, agent_uri: agent_uri, pid: pid}
  end

  describe "snapshot_buffer/2" do
    test "returns {:ok, binary} for a live PtyServer", %{agent_uri: uri} do
      assert {:ok, buf} = PtyServer.snapshot_buffer(uri)
      assert is_binary(buf)
    end

    test "tails to max_bytes", %{agent_uri: uri, pid: pid} do
      # Inject a known buffer via :sys.replace_state so the test isn't
      # dependent on actual PTY output. #1201 ①: the cut is now UTF-8
      # codepoint-boundary-aware, so on random bytes the tail may shrink
      # by up to 3 bytes (leading continuation-looking bytes are skipped).
      bigbuf = :crypto.strong_rand_bytes(200_000)
      :sys.replace_state(pid, fn s -> %{s | pty_buffer: bigbuf} end)

      assert {:ok, buf} = PtyServer.snapshot_buffer(uri, 4_096)
      assert byte_size(buf) <= 4_096
      assert byte_size(buf) >= 4_096 - 3
      # Must be the TAIL, not the head.
      assert buf == binary_part(bigbuf, byte_size(bigbuf) - byte_size(buf), byte_size(buf))
    end

    test "returns :error for unknown agent_uri" do
      ghost =
        URI.new!("entity://team-alpha/agent/test_does-not-exist-#{System.unique_integer([:positive])}")

      assert :error = PtyServer.snapshot_buffer(ghost)
    end
  end

  describe "trigger_redraw/1" do
    test "returns :ok for test_mode PtyServer (no real os_pid)", %{agent_uri: uri} do
      assert :ok = PtyServer.trigger_redraw(uri)
    end

    test "returns :error for unknown agent_uri" do
      ghost =
        URI.new!("entity://team-alpha/agent/test_does-not-exist-#{System.unique_integer([:positive])}")

      assert :error = PtyServer.trigger_redraw(ghost)
    end
  end
end
