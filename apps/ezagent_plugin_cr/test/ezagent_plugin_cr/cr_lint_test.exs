defmodule EzagentPluginCr.CrLintTest do
  use ExUnit.Case
  alias EzagentPluginCr.CrLint
  alias EzagentPluginContent.Tenant.TenantRuntime

  setup do
    tid = "test-lint-#{System.unique_integer([:positive])}"
    sandbox = TenantRuntime.sandbox_path(tid)

    # Create a valid sandbox structure
    File.mkdir_p!(sandbox)
    File.write!(Path.join(sandbox, "CLAUDE.md"), "# Test CLAUDE.md\n\nHello {{name}}!")
    File.mkdir_p!(Path.join(sandbox, "skills"))
    File.mkdir_p!(Path.join(sandbox, "skills/agent1"))
    File.write!(Path.join(sandbox, "skills/agent1/SKILL.md"), "# Agent 1\n\n{{slot1}}")
    File.mkdir_p!(Path.join(sandbox, "kb"))

    on_exit(fn -> File.rm_rf!(sandbox) end)
    {:ok, tid: tid, sandbox: sandbox}
  end

  test "all rules pass on a valid sandbox", %{tid: tid} do
    assert :ok = CrLint.check(tid)
  end

  test "R02: detects missing required files", %{sandbox: sandbox, tid: tid} do
    # Remove CLAUDE.md
    File.rm!(Path.join(sandbox, "CLAUDE.md"))
    assert {:error, reasons} = CrLint.check(tid)
    assert Enum.any?(reasons, &String.contains?(&1, "R02"))
  end

  test "R03: detects empty skill directories", %{sandbox: sandbox, tid: tid} do
    # Create an empty skill dir
    empty_dir = Path.join(sandbox, "skills/empty_skill")
    File.mkdir_p!(empty_dir)
    assert {:error, reasons} = CrLint.check(tid)
    assert Enum.any?(reasons, &String.contains?(&1, "R03"))
  end

  test "R04: detects unbalanced {{ }} slots", %{sandbox: sandbox, tid: tid} do
    File.write!(Path.join(sandbox, "CLAUDE.md"), "# Broken\n\n{{unclosed")
    assert {:error, reasons} = CrLint.check(tid)
    assert Enum.any?(reasons, &String.contains?(&1, "R04"))
  end

  test "R01: detects broken symlinks", %{sandbox: sandbox, tid: tid} do
    # Create a broken symlink
    broken = Path.join(sandbox, "broken_link")
    File.ln_s("/nonexistent/target", broken)
    assert {:error, reasons} = CrLint.check(tid)
    assert Enum.any?(reasons, &String.contains?(&1, "R01"))
  end
end
