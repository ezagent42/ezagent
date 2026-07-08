defmodule Ezagent.AgentBridge.CompleteTest do
  use ExUnit.Case, async: true

  test "complete/2 on an unresolvable agent returns {:error, _} (never raises, never leaks a key)" do
    ghost = Ezagent.URI.entity("system", :agent, "no-such-curl-agent")
    assert {:error, _} = Ezagent.AgentBridge.complete(ghost, "hello")
  end

  test "complete/2 exists with the documented arity/spec" do
    assert function_exported?(Ezagent.AgentBridge, :complete, 2)
  end

  test "Ezagent.Entity.Agent.complete/3 on a ghost agent returns {:error, :agent_owner_unresolvable}" do
    caller = Ezagent.Entity.User.admin_uri()
    ghost = Ezagent.URI.entity("system", :agent, "no-such-curl-agent")

    assert {:error, :agent_owner_unresolvable} =
             Ezagent.Entity.Agent.complete(caller, ghost, "hello")
  end

  test "complete/3 exists with the documented arity/spec" do
    assert function_exported?(Ezagent.Entity.Agent, :complete, 3)
  end
end
