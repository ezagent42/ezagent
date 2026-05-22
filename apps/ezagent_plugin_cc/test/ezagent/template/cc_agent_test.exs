defmodule Ezagent.PluginCc.Template.CcAgentTest do
  @moduledoc """
  Unified `cc.agent` Template Class. The `mode` field was removed
  Allen 2026-05-21 (V1 fix) — local-pty is the only path. Tests for
  remote-channel placeholder + mode-validation were deleted with it.

  Allen 2026-05-21 V1 fix: instantiate now spawns BOTH the Agent
  Kind (via `SpawnRegistry.spawn/1` → snapshot persistence path) AND
  the PtyServer. The Agent Kind path needs DB sandbox checkout, so
  this suite uses `EzagentCore.DataCase` rather than a plain
  `ExUnit.Case`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.CcAgent

  describe "template_name/0" do
    test "returns 'cc.agent'" do
      assert CcAgent.template_name() == "cc.agent"
    end
  end

  describe "validate/1" do
    test "accepts a well-formed template" do
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/cc_cc-architect",
                 "cwd" => "/tmp"
               })
    end

    test "tolerates legacy `mode` field (silently ignored, no migration needed)" do
      # PR-D2 migration seeded `mode: "local-pty"` into existing rows.
      # The V1 fix removed the field from the schema but did NOT
      # migrate the JSON — legacy rows must still validate, since
      # extra fields are non-load-bearing per the let-it-crash
      # principle (no shims, just structural irrelevance).
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/cc_legacy",
                 "mode" => "local-pty",
                 "cwd" => "/tmp"
               })
    end

    test "rejects missing class" do
      assert {:error, :missing_class_field} =
               CcAgent.validate(%{"agent_uri" => "entity://agent/default/cc_x", "cwd" => "/tmp"})
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "cc.pty"}} =
               CcAgent.validate(%{
                 "class" => "cc.pty",
                 "agent_uri" => "entity://agent/default/cc_x",
                 "cwd" => "/tmp"
               })
    end

    test "rejects missing agent_uri" do
      assert {:error, :missing_agent_uri} =
               CcAgent.validate(%{"class" => "cc.agent", "cwd" => "/tmp"})
    end

    test "rejects entity://user/default/X (wrong entity type — must be agent)" do
      assert {:error, {:invalid_agent_uri, _, _}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://user/default/x",
                 "cwd" => "/tmp"
               })
    end

    test "rejects non-entity scheme entirely" do
      assert {:error, {:bad_agent_uri, _}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "session://default/default/main",
                 "cwd" => "/tmp"
               })
    end

    test "rejects entity://agent/<name> without flavor prefix (PR #141)" do
      assert {:error, {:missing_flavor_prefix, _, _}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/just-a-name",
                 "cwd" => "/tmp"
               })
    end

    test "rejects wrong agent flavor in name prefix" do
      assert {:error, {:wrong_agent_flavor, "curl", expected: "cc"}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/curl_my-deepseek",
                 "cwd" => "/tmp"
               })
    end

    test "rejects missing cwd" do
      assert {:error, :missing_cwd} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/cc_x"
               })
    end
  end

  describe "instantiate/3" do
    test "spawns a PtyServer for the declared agent" do
      agent_uri_str = "entity://agent/default/cc_test-#{System.unique_integer([:positive])}"

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => "/tmp"
      }

      workspace_uri = URI.parse("workspace://test")

      assert {:ok, [returned_uri]} = CcAgent.instantiate("test-tmpl", tmpl, workspace_uri)
      assert URI.to_string(returned_uri) == agent_uri_str
    end

    test "produces BOTH the Agent Kind AND the PtyServer (V1 fix invariant)" do
      # V1 fix Allen 2026-05-21: instantiate is the sole producer of
      # the cc agent's runtime resources. After it returns:
      # 1. KindRegistry.lookup(agent_uri) must succeed — Agent Kind alive
      # 2. PtyServer.find_by_agent_uri(agent_uri) must succeed — PTY alive
      agent_uri_str = "entity://agent/default/cc_v1fix-#{System.unique_integer([:positive])}"
      agent_uri = URI.parse(agent_uri_str)

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => "/tmp"
      }

      workspace_uri = URI.parse("workspace://test")

      assert {:ok, [^agent_uri]} = CcAgent.instantiate("t", tmpl, workspace_uri)

      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive after cc.agent.instantiate (V1 fix invariant)"

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      assert {:ok, pty_pid} = Ezagent.Domain.Pty.lookup(agent_uri),
             "PtyServer must be alive after cc.agent.instantiate (V1 fix invariant)"

      assert is_pid(pty_pid)
      assert Process.alive?(pty_pid)
    end

    test "is idempotent — second call returns same URI without spawning a second PtyServer" do
      agent_uri_str = "entity://agent/default/cc_idem-#{System.unique_integer([:positive])}"
      uri = URI.parse(agent_uri_str)

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => "/tmp"
      }

      workspace_uri = URI.parse("workspace://test")

      assert {:ok, [^uri]} = CcAgent.instantiate("t", tmpl, workspace_uri)

      pids_before = list_pty_pids_for(agent_uri_str)
      assert length(pids_before) == 1

      assert {:ok, [^uri]} = CcAgent.instantiate("t", tmpl, workspace_uri)

      pids_after = list_pty_pids_for(agent_uri_str)
      assert pids_after == pids_before
    end
  end

  describe "registry integration" do
    test "Template Class is registered at boot" do
      assert {:ok, Ezagent.PluginCc.Template.CcAgent} =
               Ezagent.TemplateRegistry.lookup("cc.agent")
    end
  end

  describe "validate/1 — Phase 7 completion PR-1 extended sandbox keys (SPEC §1.5 (c))" do
    test "legacy 3-key form still validates (backward compat)" do
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/cc_legacy",
                 "cwd" => "/tmp"
               })
    end

    test "extended 7-key form validates" do
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/cc_extended",
                 "cwd" => "/tmp",
                 "operator_settings_path" => "/sandbox/settings.json",
                 "operator_mcp_config_path" => "/sandbox/mcp.json",
                 "claude_config_dir" => "/sandbox/.claude",
                 "api_key_helper" => "/sandbox/key-helper.sh"
               })
    end

    test "a non-string sandbox key is rejected" do
      assert {:error, {:invalid_sandbox_key, "claude_config_dir", _}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/cc_bad",
                 "cwd" => "/tmp",
                 "claude_config_dir" => 123
               })
    end
  end

  describe "assemble_settings_mcp_args/3 — hostile-path (SPEC §1.5 (c))" do
    @mandatory "/priv/claude-pty-settings.json"
    @bridge "/run/esr-bridge.mcp.json"

    test "with no operator keys: mandatory --settings + bridge --mcp-config only" do
      args = CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, %{})

      assert args == "--settings #{@mandatory} --mcp-config #{@bridge}"
    end

    test "an operator --settings is emitted BEFORE the mandatory one (safety last-wins)" do
      hostile = %{"operator_settings_path" => "/hostile/settings.json"}
      args = CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, hostile)

      # The mandatory file (forcing remoteControlAtStartup:false) MUST be
      # the LAST --settings. claude is last-wins per --settings file —
      # so a hostile operator file setting remoteControlAtStartup:true
      # cannot win.
      settings_args =
        args
        |> String.split(" ")
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [flag, _] -> flag == "--settings" end)
        |> Enum.map(fn [_, path] -> path end)

      assert settings_args == ["/hostile/settings.json", @mandatory],
             "operator --settings must precede the mandatory safety --settings"

      assert List.last(settings_args) == @mandatory,
             "the mandatory remoteControlAtStartup:false file must be LAST so it wins"
    end

    test "an operator --mcp-config NEVER replaces the trusted esr-bridge --mcp-config" do
      hostile = %{"operator_mcp_config_path" => "/hostile/mcp.json"}
      args = CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, hostile)

      mcp_args =
        args
        |> String.split(" ")
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [flag, _] -> flag == "--mcp-config" end)
        |> Enum.map(fn [_, path] -> path end)

      assert @bridge in mcp_args,
             "the trusted esr-bridge --mcp-config must always be present — " <>
               "an operator mcp config cannot drop it"

      assert "/hostile/mcp.json" in mcp_args,
             "operator --mcp-config is additive, not a replacement"
    end
  end

  defp list_pty_pids_for(agent_uri_str) do
    Ezagent.Domain.Pty.Server.list_agents()
    |> Enum.filter(fn a -> URI.to_string(a.agent_uri) == agent_uri_str end)
    |> Enum.map(& &1.pid)
  end
end
