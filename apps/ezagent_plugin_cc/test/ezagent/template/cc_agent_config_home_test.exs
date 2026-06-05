defmodule Ezagent.PluginCc.Template.CcAgentConfigHomeTest do
  @moduledoc """
  PR-3 (codex review P2) — `resolve_config_home/2` (the single source for BOTH
  `CLAUDE_CONFIG_DIR` and the authoritative `--mcp-config` `.mcp.json`) must NEVER
  resolve to the shared template `config_dir` reference. On the `:already_started`
  PTY-recovery path the realized `agent_config_dir` is absent but the
  domain-allocated `allocated_config_dir` is present; and even with neither, a
  present reference means the per-agent target is DERIVED from the agent URI —
  not the shared source dir (feedback_let_it_crash_no_workarounds: no
  shared-fallback).
  """
  use ExUnit.Case, async: true

  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.Sandbox.ConfigDir

  defp agent_uri, do: Ezagent.URI.new!("entity://agent/team-alpha/cc_home-#{System.unique_integer([:positive])}")

  test "realized agent_config_dir wins" do
    uri = agent_uri()
    tmpl = %{"agent_config_dir" => "/realized/per/agent", "config_dir" => "/shared/ref"}
    assert CcAgent.resolve_config_home(uri, tmpl) == "/realized/per/agent"
  end

  test "recovery path (allocated set, no agent_config_dir) → allocated, NOT the shared reference" do
    uri = agent_uri()
    allocated = ConfigDir.path(uri, "cc")
    tmpl = %{"allocated_config_dir" => allocated, "config_dir" => "/shared/ref"}

    assert CcAgent.resolve_config_home(uri, tmpl) == allocated
    refute CcAgent.resolve_config_home(uri, tmpl) == "/shared/ref"
  end

  test "reference present but no realized/allocated → DERIVE from URI, never the shared reference" do
    uri = agent_uri()
    tmpl = %{"config_dir" => "/shared/template/ref"}

    resolved = CcAgent.resolve_config_home(uri, tmpl)
    assert resolved == ConfigDir.path(uri, "cc")
    refute resolved == "/shared/template/ref"
  end

  test "no config_dir reference → nil (no config home)" do
    uri = agent_uri()
    assert CcAgent.resolve_config_home(uri, %{"cwd" => "/tmp"}) == nil
  end
end
