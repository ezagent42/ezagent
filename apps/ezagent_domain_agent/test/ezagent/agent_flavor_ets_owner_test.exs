defmodule Ezagent.AgentFlavorEtsOwnerTest do
  use ExUnit.Case, async: false

  test "domain.agent owns agent flavor registry ETS tables" do
    owner = Process.whereis(EzagentDomainAgent.EtsOwner)

    assert is_pid(owner)
    assert :ets.info(Ezagent.AgentFlavorRegistry.table(), :owner) == owner
    assert :ets.info(Ezagent.AgentFlavorAttributes.table(), :owner) == owner
  end
end
