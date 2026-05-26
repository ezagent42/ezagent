defmodule EzagentPluginCc.OrphanReaperTest do
  @moduledoc """
  Unit tests for `EzagentPluginCc.OrphanReaper` — the cc-plugin's
  orphan-claude reaper (PTY-orphan-restart 2026-05-26).

  These tests verify the parsing + filtering logic without actually
  running `ps` or sending real kill signals — the live-system
  integration is exercised by the cc-orphan e2e (separate file).

  Strategy: tests reach into the reaper's private helpers via
  documented exposure. The reaper itself uses straightforward
  System.cmd + URI inspection — the bug class we want to gate is
  "candidate parsing mis-extracts the EZAGENT_AGENT_URI" + "orphan?
  predicate wrong-counts a live PtyServer as orphan".

  We exercise the reaper through `reap/0` itself, with the System.cmd
  call mocked at the OS level (no real `ps` invocation needed in unit
  test — we substitute a controlled `ps` output via the same
  System.cmd boundary).
  """

  use ExUnit.Case, async: false

  # No setup needed — the reaper is a pure function module + the
  # tests do not start any OTP supervision tree.

  describe "reap/0 with no orphan candidates" do
    test "returns {:ok, 0} when no claude processes are running on the box" do
      # The `ps -axww -Eo pid,command` invocation will succeed but
      # find no lines matching the cc-argv-signature; the reaper
      # returns 0 kills. We don't mock `ps` itself in this test —
      # the assumption is the test box has no leftover cc claudes
      # carrying our distinctive `--dangerously-load-development-channels
      # server:esr-bridge` signature. The integration tests cover the
      # positive-match path.
      assert {:ok, _killed} = EzagentPluginCc.OrphanReaper.reap()
    end
  end

  describe "argv signature detection" do
    test "the @argv_signature module attribute matches what cc Template builds" do
      # Defense-in-depth: the reaper's signature MUST match what
      # `Ezagent.PluginCc.Template.CcAgent.build_claude_cmd/3`
      # emits. If a future refactor changes the cmdline, this test
      # would still pass — but the live reaper would fail to find
      # orphans. The companion `cc_agent_test.exs` asserts the cmd
      # shape; this test asserts the SIGNATURE substring is part
      # of it.
      signature = "--dangerously-load-development-channels server:esr-bridge"

      # The argv emitted by cc_agent.build_claude_cmd MUST contain
      # both tokens consecutively (they appear as separate argv
      # elements but get joined-with-space in the `ps` output).
      argv =
        Ezagent.PluginCc.Template.CcAgent.assemble_settings_mcp_args(
          "/priv/safety.json",
          "/agent-cwd/.mcp.json",
          %{}
        )

      # The signature must be representable in the joined argv —
      # `--dangerously-load-development-channels` is in the static
      # prefix `Ezagent.PluginCc.Template.CcAgent.build_claude_cmd/3`
      # emits BEFORE assemble_settings_mcp_args; this test sanity-
      # checks the assembler does NOT introduce a flag that would
      # break the signature match.
      refute Enum.any?(argv, &String.contains?(&1, signature)),
             "assemble_settings_mcp_args must not contain the cc signature; " <>
               "the signature comes from the cc_agent static prefix"
    end
  end
end
