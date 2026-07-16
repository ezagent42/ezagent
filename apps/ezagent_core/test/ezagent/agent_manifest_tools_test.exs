defmodule Ezagent.AgentManifest.ToolsTest do
  use ExUnit.Case, async: true

  alias Ezagent.AgentManifest.Tools
  alias Ezagent.Invocation

  test "action tool dispatches as the agent with an empty ctx.caps set" do
    agent_uri = URI.new!("entity://system/agent/tool-runner")
    target = URI.new!("session://generic/system/demo?action=session.send")
    test_pid = self()

    dispatch_fun = fn %Invocation{} = invocation ->
      send(test_pid, {:invocation, invocation})
      {:error, :unauthorized}
    end

    tool = %{
      name: "send_message",
      type: :action,
      action: URI.to_string(target),
      caps: [%{"kind" => "session"}],
      optional: false
    }

    assert {:error, :unauthorized} =
             Tools.dispatch_action(agent_uri, tool, %{"message" => "hello"},
               dispatch_fun: dispatch_fun
             )

    assert_received {:invocation,
                     %Invocation{
                       origin: :trusted_internal,
                       target: ^target,
                       mode: :call,
                       args: %{"message" => "hello"},
                       ctx: %{caller: ^agent_uri, caps: caps}
                     }}

    assert MapSet.equal?(caps, MapSet.new())
  end

  test "rejects non-action tool declarations at the action dispatcher" do
    agent_uri = URI.new!("entity://system/agent/tool-runner")

    assert {:error, {:unsupported_tool_type, :participant}} =
             Tools.dispatch_action(agent_uri, %{type: :participant}, %{})
  end
end
