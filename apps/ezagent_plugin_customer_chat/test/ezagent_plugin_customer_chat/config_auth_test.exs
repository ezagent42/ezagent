defmodule EzagentPluginCustomerChat.ConfigAuthTest do
  use ExUnit.Case, async: true
  alias EzagentPluginCustomerChat.ConfigAuth
  alias Ezagent.Capability

  test "bootstrap admin all-:any cap admits any tenant" do
    caps = [Capability.cap(:any, :any, :any)]
    assert ConfigAuth.caps_admit?(caps, "cinnox")
    assert ConfigAuth.caps_admit?(caps, "acme")
  end

  test "cross-workspace workspace-admin cap admits" do
    caps = [Capability.cap(:workspace, Ezagent.Behavior.Workspace, :any)]
    assert ConfigAuth.caps_admit?(caps, "cinnox")
  end

  test "tenant-scoped workspace-admin cap admits only its own tenant" do
    caps = [
      Capability.cap(
        :workspace,
        Ezagent.Behavior.Workspace,
        :any,
        :any,
        URI.parse("workspace://cinnox")
      )
    ]

    assert ConfigAuth.caps_admit?(caps, "cinnox")
    refute ConfigAuth.caps_admit?(caps, "acme")
  end

  test "responder Mode.set cap does NOT admit" do
    caps = [
      Capability.cap(:session, Ezagent.Behavior.Mode, :set, :any, URI.parse("workspace://cinnox"))
    ]

    refute ConfigAuth.caps_admit?(caps, "cinnox")
  end

  test "a workspace-admin behavior cap with a NON-:any action does NOT admit (action axis)" do
    # Right kind + behavior + workspace, but action :read (not :any). The needed
    # shape requires action :any, so the action axis alone rejects it — isolating
    # the action-axis check from the kind/behavior mismatch the responder test covers.
    caps = [
      Capability.cap(
        :workspace,
        Ezagent.Behavior.Workspace,
        :read,
        :any,
        URI.parse("workspace://cinnox")
      )
    ]

    refute ConfigAuth.caps_admit?(caps, "cinnox")
  end

  test "no caps does not admit" do
    refute ConfigAuth.caps_admit?([], "cinnox")
  end
end
