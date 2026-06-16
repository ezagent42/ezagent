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
    assert {:ok, %{warnings: [], ok: ok_results}} = CrLint.check(tid)
    assert length(ok_results) == 5
  end

  test "R01: detects broken symlinks as error", %{sandbox: sandbox, tid: tid} do
    broken = Path.join(sandbox, "broken_link")
    File.ln_s("/nonexistent/target", broken)
    assert {:error, %{errors: errors}} = CrLint.check(tid)
    assert Enum.any?(errors, fn {:error, msg} -> String.contains?(msg, "R01") end)
  end

  test "R02: detects missing required files as error", %{sandbox: sandbox, tid: tid} do
    File.rm!(Path.join(sandbox, "CLAUDE.md"))
    assert {:error, %{errors: errors}} = CrLint.check(tid)
    assert Enum.any?(errors, fn {:error, msg} -> String.contains?(msg, "R02") end)
  end

  test "R03: detects empty skill directories as warning", %{sandbox: sandbox, tid: tid} do
    empty_dir = Path.join(sandbox, "skills/empty_skill")
    File.mkdir_p!(empty_dir)
    assert {:ok, %{warnings: warnings}} = CrLint.check(tid)
    assert Enum.any?(warnings, fn {:warning, msg} -> String.contains?(msg, "R03") end)
  end

  test "R04: detects unbalanced {{ }} slots as warning", %{sandbox: sandbox, tid: tid} do
    File.write!(Path.join(sandbox, "CLAUDE.md"), "# Broken\n\n{{unclosed")
    assert {:ok, %{warnings: warnings}} = CrLint.check(tid)
    assert Enum.any?(warnings, fn {:warning, msg} -> String.contains?(msg, "R04") end)
  end

  test "R05: detects empty kb.db as error", %{sandbox: sandbox, tid: tid} do
    File.mkdir_p!(Path.join(sandbox, "kb"))
    File.write!(Path.join(sandbox, "kb/kb.db"), "")
    assert {:error, %{errors: errors}} = CrLint.check(tid)
    assert Enum.any?(errors, fn {:error, msg} -> String.contains?(msg, "R05") end)
  end
end
