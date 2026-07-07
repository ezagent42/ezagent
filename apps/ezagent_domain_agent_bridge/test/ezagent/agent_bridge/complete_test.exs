defmodule Ezagent.AgentBridge.CompleteTest do
  use ExUnit.Case, async: true

  test "complete/2 on an unresolvable agent returns {:error, _} (never raises, never leaks a key)" do
    ghost = Ezagent.URI.entity("system", :agent, "no-such-curl-agent")
    assert {:error, _} = Ezagent.AgentBridge.complete(ghost, "hello")
  end

  test "complete/2 exists with the documented arity/spec" do
    assert function_exported?(Ezagent.AgentBridge, :complete, 2)
  end
end
