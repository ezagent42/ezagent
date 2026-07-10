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

  describe "sdk_sidecar_params/2 threading" do
    test "threads cwd / config_dir / MCP surface / process env from the template" do
      agent_uri = Ezagent.URI.new!("entity://test-ws/agent/cc_headless_params")

      tmpl = %{
        "class" => "cc_headless.agent",
        "agent_uri" => URI.to_string(agent_uri),
        "cwd" => "/tmp/agent-cwd",
        # resolve_config_home returns agent_config_dir verbatim when a valid
        # dir string is present (no filesystem access) — this is the config
        # dir the worker points `mcp_servers` at.
        "agent_config_dir" => "/tmp/agent-cfg",
        "allowed_tools" => ["Bash"],
        "mcp_servers" => %{"custom" => %{"type" => "stdio", "command" => "x"}},
        # Bridge identity env the MCP servers claude launches read from
        # os.environ (EZAGENT_AGENT_URI / EZAGENT_AGENT_TOKEN / WS_URL).
        "cmd_env" => %{"EZAGENT_AGENT_URI" => "agent://x", "EZAGENT_AGENT_TOKEN" => "tok"}
      }

      params = CcHeadlessAgent.sdk_sidecar_params(agent_uri, tmpl)

      assert params.cwd == "/tmp/agent-cwd"
      assert params.config_dir == "/tmp/agent-cfg"
      assert params.allowed_tools == ["Bash"]
      assert params.mcp_servers == %{"custom" => %{"type" => "stdio", "command" => "x"}}

      assert params.cmd_env == %{
               "EZAGENT_AGENT_URI" => "agent://x",
               "EZAGENT_AGENT_TOKEN" => "tok"
             }
    end

    test "cmd_env defaults to nil when the template carries no process env" do
      agent_uri = Ezagent.URI.new!("entity://test-ws/agent/cc_headless_noenv")

      tmpl = %{
        "class" => "cc_headless.agent",
        "agent_uri" => URI.to_string(agent_uri),
        "cwd" => "/tmp/agent-cwd",
        "agent_config_dir" => "/tmp/agent-cfg"
      }

      params = CcHeadlessAgent.sdk_sidecar_params(agent_uri, tmpl)

      assert params.cmd_env == nil
      assert params.config_dir == "/tmp/agent-cfg"
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
end
