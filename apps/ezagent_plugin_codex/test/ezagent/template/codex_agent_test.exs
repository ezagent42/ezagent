defmodule Ezagent.PluginCodex.Template.CodexAgentTest do
  use ExUnit.Case, async: true

  alias Ezagent.PluginCodex.Template.CodexAgent

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
