defmodule Ezagent.PluginCodex.Template.CodexRemoteAgentTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCodex.Template.CodexRemoteAgent

  test "instantiate/4 forwards the identical launch context to LocalRuntime" do
    launch_context = make_ref()
    suffix = System.unique_integer([:positive])

    tmpl = %{
      "class" => "codex_remote.agent",
      "agent_uri" => "entity://test/agent/codex-remote-launch-#{suffix}",
      "cwd" => "/tmp"
    }

    Ezagent.Agent.TemplateLaunchTrace.trace_call(
      Ezagent.LocalRuntime,
      :ensure_started_detailed,
      2,
      fn ->
        assert {:error, _reason} =
                 CodexRemoteAgent.instantiate("test", tmpl, URI.new!("workspace://test"),
                   launch_context: launch_context
                 )

        assert_receive {:trace, _, :call,
                        {Ezagent.LocalRuntime, :ensure_started_detailed,
                         [_, [launch_context: ^launch_context]]}}
      end
    )
  end

  test "instantiate/3 remains available and sole-option validation uses valid data" do
    assert function_exported?(CodexRemoteAgent, :instantiate, 3)
    assert function_exported?(CodexRemoteAgent, :instantiate, 4)

    assert {:error, {:invalid_template, %{}}} =
             CodexRemoteAgent.instantiate("test", %{}, URI.new!("workspace://test"))

    tmpl = %{
      "class" => "codex_remote.agent",
      "agent_uri" => "entity://test/agent/codex-remote-invalid-options",
      "cwd" => "/tmp"
    }

    assert {:error, :invalid_launch_options} =
             CodexRemoteAgent.instantiate("test", tmpl, URI.new!("workspace://test"),
               launch_context_typo: make_ref()
             )
  end

  describe "template_name/0" do
    test "returns codex_remote.agent" do
      assert CodexRemoteAgent.template_name() == "codex_remote.agent"
    end
  end

  describe "config_dir_namespace/0" do
    test "returns codex-remote (separate from codex)" do
      assert CodexRemoteAgent.config_dir_namespace() == "codex-remote"
    end
  end

  describe "validate/1" do
    test "accepts valid template" do
      tmpl = %{
        "class" => "codex_remote.agent",
        "agent_uri" => "entity://test-ws/agent/codex_remote_test",
        "cwd" => "/tmp"
      }

      assert CodexRemoteAgent.validate(tmpl) == :ok
    end

    test "rejects missing class" do
      assert {:error, :missing_class_field} =
               CodexRemoteAgent.validate(%{"agent_uri" => "entity://t/agent/ws_n", "cwd" => "/"})
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "codex.agent"}} =
               CodexRemoteAgent.validate(%{
                 "class" => "codex.agent",
                 "agent_uri" => "entity://t/agent/ws_n",
                 "cwd" => "/"
               })
    end

    test "rejects missing cwd" do
      assert {:error, :missing_cwd} =
               CodexRemoteAgent.validate(%{
                 "class" => "codex_remote.agent",
                 "agent_uri" => "entity://t/agent/ws_n"
               })
    end

    test "accepts optional model/sandbox/approval_policy" do
      tmpl = %{
        "class" => "codex_remote.agent",
        "agent_uri" => "entity://test-ws/agent/codex_remote_full",
        "cwd" => "/tmp",
        "model" => "some-model",
        "approval_policy" => "never",
        "sandbox" => "read-only"
      }

      assert CodexRemoteAgent.validate(tmpl) == :ok
    end

    test "rejects invalid sandbox type" do
      assert {:error, {:invalid_string_field, "sandbox", 123}} =
               CodexRemoteAgent.validate(%{
                 "class" => "codex_remote.agent",
                 "agent_uri" => "entity://t/agent/ws_n",
                 "cwd" => "/",
                 "sandbox" => 123
               })
    end
  end

  describe "CredentialAdapter delegation" do
    alias Ezagent.PluginCodex.Template.CodexAgent

    test "credential_env_var delegates to CodexAgent" do
      assert CodexRemoteAgent.credential_env_var() == CodexAgent.credential_env_var()
      assert CodexRemoteAgent.credential_env_var() == "CODEX_HOME"
    end

    test "credential_relpaths delegates to CodexAgent" do
      assert CodexRemoteAgent.credential_relpaths() == CodexAgent.credential_relpaths()
    end

    test "secret_relpaths delegates to CodexAgent" do
      assert CodexRemoteAgent.secret_relpaths() == CodexAgent.secret_relpaths()
    end

    test "auth_failure_signals delegates to CodexAgent" do
      # Regex structs are never `==` across separate compilations
      # (`~r/a/ == ~r/a/` is false), so compare by inspected form.
      assert Enum.map(CodexRemoteAgent.auth_failure_signals(), &inspect/1) ==
               Enum.map(CodexAgent.auth_failure_signals(), &inspect/1)
    end
  end

  describe "template_data_extra/1" do
    test "delegates to CodexAgent" do
      content = %{model: "test-model", approval_policy: "never", sandbox: "read-only"}

      assert CodexRemoteAgent.template_data_extra(content) ==
               Ezagent.PluginCodex.Template.CodexAgent.template_data_extra(content)
    end
  end

  describe "bridge topic" do
    test "uses codex-remote flavor in AgentBridge topic" do
      agent_uri = URI.new!("entity://test-ws/agent/codex_remote_full")

      assert CodexRemoteAgent.remote_bridge_topic(agent_uri) ==
               "agent_bridge:codex-remote:entity://test-ws/agent/codex_remote_full"
    end
  end
end
