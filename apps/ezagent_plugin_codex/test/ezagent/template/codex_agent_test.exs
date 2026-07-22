defmodule Ezagent.PluginCodex.Template.CodexAgentTest do
  use ExUnit.Case, async: false

  alias Ezagent.PluginCodex.Template.CodexAgent

  test "instantiate/4 forwards the identical launch context to LocalRuntime" do
    launch_context = make_ref()
    agent_uri = "entity://test/agent/codex-launch-#{System.unique_integer([:positive])}"

    tmpl = %{"class" => "codex.agent", "agent_uri" => agent_uri, "cwd" => "/tmp"}

    Ezagent.Agent.TemplateLaunchTrace.trace_call(
      Ezagent.LocalRuntime,
      :ensure_started_detailed,
      2,
      fn ->
        assert {:error, _reason} =
                 CodexAgent.instantiate("test", tmpl, URI.new!("workspace://test"),
                   launch_context: launch_context
                 )

        assert_receive {:trace, _, :call,
                        {Ezagent.LocalRuntime, :ensure_started_detailed,
                         [_, [launch_context: ^launch_context]]}}
      end
    )
  end

  test "instantiate/3 remains available and sole-option validation uses valid data" do
    assert function_exported?(CodexAgent, :instantiate, 3)
    assert function_exported?(CodexAgent, :instantiate, 4)

    assert {:error, {:invalid_template, %{}}} =
             CodexAgent.instantiate("test", %{}, URI.new!("workspace://test"))

    tmpl = %{
      "class" => "codex.agent",
      "agent_uri" => "entity://test/agent/codex-invalid-options",
      "cwd" => "/tmp"
    }

    assert {:error, :invalid_launch_options} =
             CodexAgent.instantiate("test", tmpl, URI.new!("workspace://test"),
               launch_context_typo: make_ref()
             )
  end

  describe "validate/1 — agent_uri" do
    test "accepts entity://agent/<name> without flavor prefix" do
      assert :ok =
               CodexAgent.validate(%{
                 "class" => "codex.agent",
                 "agent_uri" => "entity://team-alpha/agent/just-a-name",
                 "cwd" => "/tmp"
               })
    end

    test "ignores legacy name prefix when validating stored flavor" do
      assert :ok =
               CodexAgent.validate(%{
                 "class" => "codex.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_wrong-prefix",
                 "cwd" => "/tmp"
               })
    end
  end
end
