defmodule Ezagent.Entity.AgentCompleteAuthorizationTest do
  @moduledoc """
  Deny path for `Ezagent.Entity.Agent.complete/3` cap-gating (#1239 finalize ①).

  The ghost-agent tests in the bridge app only cover the owner-unresolvable
  short-circuit; nothing exercised `authorize_complete/4` itself. These pin
  the branch AFTER lineage resolves: a caller that is neither the agent's
  owner nor a holder of `cap(:agent, ActionSet.Agent.Complete, :complete,
  agent_uri, ws)` must get `{:error, :unauthorized}` and never reach bridge
  delivery, while the owner passes authorization unconditionally.
  """
  use EzagentCore.DataCase, async: false

  defp uris do
    uniq = System.unique_integer([:positive])

    %{
      agent: Ezagent.URI.new!("entity://team-alpha/agent/curl-llm-#{uniq}"),
      owner: Ezagent.URI.new!("entity://team-alpha/user/owner-#{uniq}"),
      stranger: Ezagent.URI.new!("entity://team-alpha/user/stranger-#{uniq}")
    }
  end

  test "non-owner caller without the Complete cap → {:error, :unauthorized}" do
    %{agent: agent, owner: owner, stranger: stranger} = uris()

    :ok = Ezagent.AgentLineage.record(agent, owner)

    assert {:error, :unauthorized} =
             Ezagent.Entity.Agent.complete(stranger, agent, "hello")
  end

  test "owner caller passes authorization (fails later at delivery, never :unauthorized)" do
    %{agent: agent, owner: owner} = uris()

    :ok = Ezagent.AgentLineage.record(agent, owner)

    # The agent URI has lineage but no live Kind/snapshot, so delivery
    # fails downstream — the pin is that authorization did NOT deny.
    assert {:error, reason} = Ezagent.Entity.Agent.complete(owner, agent, "hello")
    refute reason == :unauthorized
  end
end
