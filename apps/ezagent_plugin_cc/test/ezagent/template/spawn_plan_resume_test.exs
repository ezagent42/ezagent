defmodule Ezagent.PluginCc.Template.SpawnPlanResumeTest do
  @moduledoc """
  cc-PTY hardening 2026-07-10 (audit #2) — respawn resumes the conversation.

  A respawned `claude` must resume the SAME conversation (`--continue`) instead
  of silently starting fresh and losing the whole session. The respawn path
  injects the flag into the already-built argv via
  `SpawnPlan.inject_resume_flag/1`; fresh spawns leave the argv untouched.

  ## 2026-07-13 — the flag must never be able to PREVENT a start

  `--continue` does NOT degrade gracefully when nothing is resumable: on claude
  2.1.162 it prints "No conversation found to continue" and exits 1. On the respawn
  path that is a permanent deadlock — the crash means nothing is resumable, the flag
  then guarantees the next start fails too, so nothing ever becomes resumable
  (`test-zyli-cc-1` respawned 933 times in two hours this way).

  So injection now ALSO records the pre-injection argv as `:cmd_fallback`, which the
  PTY spawn path uses when the resumed command cannot come up. Resuming is still
  preferred; it just can no longer be fatal. See
  `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.md`.
  """
  use ExUnit.Case, async: true

  alias Ezagent.PluginCc.Template.SpawnPlan

  test "resume_flag/0 is claude's --continue" do
    assert SpawnPlan.resume_flag() == "--continue"
  end

  test "inject_resume_flag/1 inserts --continue right after the claude binary" do
    params = %{
      cwd: "/tmp",
      cmd_override: [
        "/usr/local/bin/claude",
        "--dangerously-skip-permissions",
        "--dangerously-load-development-channels",
        "server:esr-bridge"
      ],
      cmd_env: %{}
    }

    updated = SpawnPlan.inject_resume_flag(params)

    assert updated.cmd_override == [
             "/usr/local/bin/claude",
             "--continue",
             "--dangerously-skip-permissions",
             "--dangerously-load-development-channels",
             "server:esr-bridge"
           ]

    # element 0 must stay the executable (erlexec execve target), and --continue
    # must be present exactly once.
    assert hd(updated.cmd_override) == "/usr/local/bin/claude"
    assert Enum.count(updated.cmd_override, &(&1 == "--continue")) == 1
  end

  test "inject_resume_flag/1 is idempotent — never double --continue" do
    params = %{cmd_override: ["/bin/claude", "--continue", "--flag"]}
    assert SpawnPlan.inject_resume_flag(params) == params
  end

  test "inject_resume_flag/1 leaves a :test-mode params map (no argv) untouched" do
    test_params = %{cwd: "/tmp", test_mode: true}
    assert SpawnPlan.inject_resume_flag(test_params) == test_params
  end

  test "inject_resume_flag/1 leaves an unexpected/empty argv shape untouched" do
    assert SpawnPlan.inject_resume_flag(%{cmd_override: []}) == %{cmd_override: []}
    assert SpawnPlan.inject_resume_flag(%{other: 1}) == %{other: 1}
  end

  describe "cmd_fallback — --continue can never PREVENT a start (2026-07-13)" do
    test "injection records the pre-injection argv as the degraded fallback" do
      fresh_argv = [
        "/usr/local/bin/claude",
        "--dangerously-skip-permissions",
        "server:esr-bridge"
      ]

      updated = SpawnPlan.inject_resume_flag(%{cwd: "/tmp", cmd_override: fresh_argv})

      # The preferred command resumes...
      assert "--continue" in updated.cmd_override

      # ...and the fallback is that SAME argv without the flag: a fresh conversation,
      # which is the whole point — losing context on a restart is a regression, never
      # starting at all is fatal.
      assert updated.cmd_fallback == fresh_argv
      refute "--continue" in updated.cmd_fallback
      assert hd(updated.cmd_fallback) == "/usr/local/bin/claude"
    end

    test "the fallback is what the PTY breaker needs: a command with no resume flag" do
      updated = SpawnPlan.inject_resume_flag(%{cmd_override: ["/bin/claude", "--flag"]})

      # Without this, a respawn whose `--continue` cannot resolve has nothing to fall
      # back to and simply re-runs the doomed command until the breaker halts it — the
      # agent would stay DOWN rather than healing itself onto a fresh conversation.
      assert updated.cmd_fallback == ["/bin/claude", "--flag"]
    end

    test "an argv that already resumes is returned unchanged — and gains no fallback" do
      # Idempotent path: nothing was injected, so there is nothing to fall back FROM.
      params = %{cmd_override: ["/bin/claude", "--continue", "--flag"]}
      assert SpawnPlan.inject_resume_flag(params) == params
      refute Map.has_key?(SpawnPlan.inject_resume_flag(params), :cmd_fallback)
    end
  end
end
