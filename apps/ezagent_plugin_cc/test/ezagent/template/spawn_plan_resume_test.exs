defmodule Ezagent.PluginCc.Template.SpawnPlanResumeTest do
  @moduledoc """
  cc-PTY hardening 2026-07-10 (audit #2) — respawn resumes the conversation.

  A respawned `claude` must resume the SAME conversation (`--continue`) instead
  of silently starting fresh and losing the whole session. The respawn path
  injects the flag into the already-built argv via
  `SpawnPlan.inject_resume_flag/1`; fresh spawns leave the argv untouched.
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
end
