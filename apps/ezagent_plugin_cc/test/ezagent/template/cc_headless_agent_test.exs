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
end
