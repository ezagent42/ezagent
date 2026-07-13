defmodule Ezagent.ActionSet.KanbanDataOwnerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, CapabilityRegistry}
  alias Ezagent.ActionSet.Kanban

  test "delegates concrete board ownership to the canonical ApiKeys resolver" do
    suffix = System.unique_integer([:positive])
    board = Ezagent.URI.new!("entity://acme/agent/kanban-board-#{suffix}")
    owner = Ezagent.URI.new!("entity://acme/user/owner-#{suffix}")

    :ok = Ezagent.AgentLineage.record(board, owner)

    assert CapabilityRegistry.data_owner_of(Kanban, board) == owner
  end

  test "allows a non-admin owner to authorize a concrete board cap" do
    suffix = System.unique_integer([:positive])
    board = Ezagent.URI.new!("entity://acme/agent/kanban-authorize-test-#{suffix}")
    owner = Ezagent.URI.new!("entity://acme/user/owner-#{suffix}")
    workspace = Ezagent.URI.new!("workspace://acme")

    :ok = Ezagent.AgentLineage.record(board, owner)

    cap = Capability.cap(:agent, Kanban, :set_status, board, workspace)

    assert :ok = CapabilityRegistry.authorize_grant(MapSet.new(), cap, %{caller: owner})
  end
end
