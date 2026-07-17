defmodule Ezagent.PluginCc.Template.CcHeadlessAgentTest do
  use EzagentCore.DataCase, async: true

  alias Ezagent.PluginCc.Template.CcHeadlessAgent

  describe "template_name/0" do
    test "returns cc_headless.agent" do
      assert CcHeadlessAgent.template_name() == "cc_headless.agent"
    end
  end

  describe "config_dir_namespace/0" do
    test "returns cc-headless (separate from cc)" do
      assert CcHeadlessAgent.config_dir_namespace() == "cc-headless"
    end
  end

  describe "validate/1" do
    test "accepts valid template" do
      tmpl = %{
        "class" => "cc_headless.agent",
        "agent_uri" => "entity://test-ws/agent/cc_headless_test",
        "cwd" => "/tmp"
      }

      assert CcHeadlessAgent.validate(tmpl) == :ok
    end

    test "rejects missing class" do
      assert {:error, :missing_class_field} =
               CcHeadlessAgent.validate(%{
                 "agent_uri" => "entity://t/agent/ws_n",
                 "cwd" => "/"
               })
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "cc.agent"}} =
               CcHeadlessAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://t/agent/ws_n",
                 "cwd" => "/"
               })
    end

    test "rejects missing cwd" do
      assert {:error, :missing_cwd} =
               CcHeadlessAgent.validate(%{
                 "class" => "cc_headless.agent",
                 "agent_uri" => "entity://t/agent/ws_n"
               })
    end

    test "accepts optional config_dir" do
      tmpl = %{
        "class" => "cc_headless.agent",
        "agent_uri" => "entity://test-ws/agent/cc_headless_cd",
        "cwd" => "/tmp",
        "config_dir" => "/tmp/config"
      }

      assert CcHeadlessAgent.validate(tmpl) == :ok
    end
  end

  describe "CredentialAdapter delegation" do
    alias Ezagent.PluginCc.Template.CcAgent

    test "credential_env_var delegates to CcAgent" do
      assert CcHeadlessAgent.credential_env_var() == CcAgent.credential_env_var()
      assert CcHeadlessAgent.credential_env_var() == "CLAUDE_CONFIG_DIR"
    end

    test "credential_relpaths delegates to CcAgent" do
      assert CcHeadlessAgent.credential_relpaths() == CcAgent.credential_relpaths()
    end

    test "secret_relpaths delegates to CcAgent" do
      assert CcHeadlessAgent.secret_relpaths() == CcAgent.secret_relpaths()
    end

    test "auth_failure_signals delegates to CcAgent" do
      # Regex structs are never `==` across separate compilations
      # (`~r/a/ == ~r/a/` is false), so compare by inspected form.
      assert Enum.map(CcHeadlessAgent.auth_failure_signals(), &inspect/1) ==
               Enum.map(CcAgent.auth_failure_signals(), &inspect/1)
    end

    # #1309 — cc-headless must expose the OPTIONAL `host_login_dir/0` callback
    # identically to cc, or the installer host-login adoption chain no-ops and the
    # agent boots into an empty config home ("Not logged in" / 401). Its omission
    # produced no compiler warning (optional callback), so this locks parity.
    test "host_login_dir is exported and delegates to CcAgent (host-login parity)" do
      assert function_exported?(CcHeadlessAgent, :host_login_dir, 0),
             "cc-headless must implement host_login_dir/0 (optional CredentialAdapter callback) " <>
               "or CredentialAdapter.host_login_source_dir/1 resolves :none and #1209 adoption no-ops"

      assert CcHeadlessAgent.host_login_dir() == CcAgent.host_login_dir()
    end
  end

  describe "template_data_extra/1" do
    test "delegates to CcAgent" do
      content = %{settings_path: "/tmp/settings.json", mcp_config_path: "/tmp/mcp.json"}

      assert CcHeadlessAgent.template_data_extra(content) ==
               Ezagent.PluginCc.Template.CcAgent.template_data_extra(content)
    end
  end

  # ── G1 gate: R1 skill loading — sdk_sidecar_params ──────────────────────

  describe "sdk_sidecar_params/2 — G1 gate: plugins + persona" do
    setup do
      tmp_dir = System.tmp_dir!()

      agent_uri =
        Ezagent.URI.new!(
          "entity://test-ws/agent/cc-headless-g1-#{System.unique_integer([:positive])}"
        )

      {:ok, agent_uri: agent_uri, tmp_dir: tmp_dir}
    end

    # #1323 threading lock: the launch glue must hand the sidecar the agent's
    # cwd / config_dir / explicit MCP surface unchanged — config_dir is the
    # anchor the worker resolves `.mcp.json` from (route B).
    test "threads cwd / config_dir / explicit mcp_servers from the template", ctx do
      tmpl = %{
        "class" => "cc_headless.agent",
        "cwd" => "/tmp/agent-cwd",
        # resolve_config_home returns agent_config_dir verbatim when present
        # (post-materialization key) — the dir the worker points mcp_servers at.
        "agent_config_dir" => "/tmp/agent-cfg",
        "allowed_tools" => ["Bash"],
        "mcp_servers" => %{"custom" => %{"type" => "stdio", "command" => "x"}}
      }

      params = CcHeadlessAgent.sdk_sidecar_params(ctx.agent_uri, tmpl)

      assert params.cwd == "/tmp/agent-cwd"
      assert params.config_dir == "/tmp/agent-cfg"
      assert params.allowed_tools == ["Bash"]
      assert params.mcp_servers == %{"custom" => %{"type" => "stdio", "command" => "x"}}
    end

    # PTY parity (live e2e 2026-07-17): PTY `claude` runs with
    # `--dangerously-skip-permissions` (spawn_plan.ex argv); headless ran
    # `permission_mode=default`, so with NOBODY able to answer a prompt, every
    # Read of skill references / Bash outside cwd / Write hung on approval and
    # the kanban-assistant could not execute its own skill. The real boundary
    # for a role-agent is CapBAC on every CLI dispatch — not the local prompt.
    test "permission_mode defaults to bypassPermissions (PTY parity), template overrides", ctx do
      base = %{"cwd" => "/tmp/agent-cwd", "agent_config_dir" => "/tmp/agent-cfg"}

      assert CcHeadlessAgent.sdk_sidecar_params(ctx.agent_uri, base).permission_mode ==
               "bypassPermissions"

      explicit = Map.put(base, "permission_mode", "default")

      assert CcHeadlessAgent.sdk_sidecar_params(ctx.agent_uri, explicit).permission_mode ==
               "default"
    end

    test "includes plugins when config_dir has .claude-plugin/plugin.json", ctx do
      config_dir = Path.join(ctx.tmp_dir, "g1-plugin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(config_dir, ".claude-plugin"))
      File.write!(Path.join([config_dir, ".claude-plugin", "plugin.json"]), "{}")

      on_exit(fn -> File.rm_rf(config_dir) end)

      # Use "agent_config_dir" (the post-materialization key set by
      # put_agent_config_dir/2) so resolve_config_home/4 returns it
      # directly without deriving a path from the agent URI.
      tmpl = %{
        "cwd" => ctx.tmp_dir,
        "agent_config_dir" => config_dir
      }

      params = CcHeadlessAgent.sdk_sidecar_params(ctx.agent_uri, tmpl)

      assert is_list(params.plugins), "plugins must be a list"
      refute params.plugins == [], "plugins must not be empty when plugin manifest exists"

      plugin = List.first(params.plugins)
      assert is_map(plugin), "each plugin entry must be a map"
      assert plugin["type"] == "local", "plugin type must be 'local'"
      assert plugin["path"] == config_dir, "plugin path must be the config_dir"
    end

    test "plugins is empty list when config_dir has no .claude-plugin/" do
      config_dir =
        Path.join(System.tmp_dir!(), "g1-noplugin-#{System.unique_integer([:positive])}")

      # Directory exists but no .claude-plugin/ subdirectory
      File.mkdir_p!(config_dir)

      on_exit(fn -> File.rm_rf(config_dir) end)

      tmpl = %{
        "cwd" => System.tmp_dir!(),
        "config_dir" => config_dir
      }

      params =
        CcHeadlessAgent.sdk_sidecar_params(
          %URI{} = Ezagent.URI.new!("entity://test-ws/agent/noplugin"),
          tmpl
        )

      assert params.plugins == [], "plugins must be empty when no plugin manifest"
    end

    test "system_prompt reads from sandbox_content.prompt (persona path)" do
      persona = "这是角色的预设 persona。"

      tmpl = %{
        "cwd" => System.tmp_dir!(),
        "sandbox_content" => %{skills: [], plugins: [], prompt: persona}
      }

      params =
        CcHeadlessAgent.sdk_sidecar_params(
          Ezagent.URI.new!("entity://test-ws/agent/persona"),
          tmpl
        )

      assert params.system_prompt == persona,
             "system_prompt must come from sandbox_content.prompt"
    end

    test "explicit system_prompt overrides sandbox_content.prompt" do
      explicit = "operator override"
      persona = "recipe persona"

      tmpl = %{
        "cwd" => System.tmp_dir!(),
        "system_prompt" => explicit,
        "sandbox_content" => %{skills: [], plugins: [], prompt: persona}
      }

      params =
        CcHeadlessAgent.sdk_sidecar_params(
          Ezagent.URI.new!("entity://test-ws/agent/explicit"),
          tmpl
        )

      assert params.system_prompt == explicit,
             "explicit system_prompt must override sandbox_content.prompt"
    end

    test "ensure_skill_tool adds Skill when plugins configured and allowed_tools explicit" do
      config_dir = Path.join(System.tmp_dir!(), "g1-skill-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(config_dir, ".claude-plugin"))
      File.write!(Path.join([config_dir, ".claude-plugin", "plugin.json"]), "{}")

      on_exit(fn -> File.rm_rf(config_dir) end)

      # Use "agent_config_dir" so resolve_config_home returns it directly.
      # Simulate #1323 pattern: explicit allowed_tools with MCP tools but no Skill
      tmpl = %{
        "cwd" => System.tmp_dir!(),
        "agent_config_dir" => config_dir,
        "allowed_tools" => ["Read", "Bash", "mcp__playwright"]
      }

      params =
        CcHeadlessAgent.sdk_sidecar_params(
          Ezagent.URI.new!("entity://test-ws/agent/skill-merge"),
          tmpl
        )

      assert "Skill" in params.allowed_tools,
             "Skill must be merged into explicit allowed_tools when plugins are configured (G1 gate)"

      assert "mcp__playwright" in params.allowed_tools,
             "existing MCP tools must be preserved (#1323 merge)"
    end

    test "allowed_tools stays nil when nil and plugins configured (let SDK defaults apply)" do
      config_dir =
        Path.join(System.tmp_dir!(), "g1-default-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(config_dir, ".claude-plugin"))
      File.write!(Path.join([config_dir, ".claude-plugin", "plugin.json"]), "{}")

      on_exit(fn -> File.rm_rf(config_dir) end)

      tmpl = %{
        "cwd" => System.tmp_dir!(),
        "agent_config_dir" => config_dir
        # No allowed_tools key — SDK defaults apply
      }

      params =
        CcHeadlessAgent.sdk_sidecar_params(
          Ezagent.URI.new!("entity://test-ws/agent/default-tools"),
          tmpl
        )

      assert is_nil(params.allowed_tools),
             "allowed_tools must stay nil when not explicitly set (let SDK defaults apply)"
    end
  end
end
