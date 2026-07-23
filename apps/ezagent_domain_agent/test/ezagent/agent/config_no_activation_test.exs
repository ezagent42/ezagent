defmodule Ezagent.Agent.ConfigNoActivationTest do
  @moduledoc """
  FP5 S5 (#115) regression: `Ezagent.Agent.Config.read_cascade/4` must read the
  config cascade from the durable `ConfigStore` WITHOUT spawning / activating
  the target agent Kind.

  The bug: the world config DETAIL surface dispatched `config_evolve.read_cascade`
  (`:call`), which lazy-spawns + force-activates a cold agent. A cold `cc` agent
  needs >5s to launch claude + click its startup dialogs, exceeding the 5s
  ReadyGate budget → `{:error, :activate_timeout}`. The fix reads the cascade
  directly (pure DB) after authorizing, so a cold agent is NEVER activated.

  These tests use a COLD agent — its Kind is deliberately NEVER spawned — and
  assert `KindRegistry.lookup/1` returns `:error` both BEFORE and AFTER the read
  (no process was started), while the cascade still resolves and the cap gate
  still rejects an unauthorized / wrong-agent caller.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.Config
  alias Ezagent.CreatorGrant
  alias Ezagent.Socialware.ConfigStore

  @default_key "agent.soul"

  setup do
    name = "cold-#{System.unique_integer([:positive])}"
    # COLD agent: a valid agent URI, but we NEVER call Ezagent.Kind.spawn/2.
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)
    workspace = Ezagent.Capability.workspace_of(agent)

    # The agent Kind must NOT be live for this scenario.
    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent))

    manager = grant_manage_cap(agent, workspace)
    %{agent: agent, workspace: workspace, manager: manager}
  end

  test "read_cascade resolves WITHOUT spawning/activating the cold agent", %{
    agent: agent,
    workspace: workspace,
    manager: manager
  } do
    # Seed a durable config object directly in the store (no Kind involved).
    {:ok, _} =
      ConfigStore.write_and_point(%{
        layer: :user,
        workspace_uri: workspace,
        subject_uri: agent,
        key: @default_key,
        body: %{"tone" => "decisive"},
        actor_uri: manager.uri,
        source_turn_id: "cold:#{System.unique_integer([:positive])}"
      })

    refute kind_live?(agent), "precondition: agent Kind must be cold before the read"

    assert {:ok, cascade} = Config.read_cascade(agent, manager.uri, manager.caps)

    # The durable cascade resolved correctly.
    assert cascade.agent_uri == URI.to_string(agent)
    [state] = cascade.keys
    assert state.effective_body == %{"tone" => "decisive"}

    # THE INVARIANT: the read did NOT start the agent Kind process.
    refute kind_live?(agent),
           "read_cascade activated the agent — it must read the snapshot/store, not dispatch"
  end

  test "read_cascade still rejects an unauthorized caller without activating", %{agent: agent} do
    stranger = Ezagent.URI.entity(:team_alpha, :user, "stranger")

    assert {:error, :unauthorized} = Config.read_cascade(agent, stranger, MapSet.new())
    refute kind_live?(agent)
  end

  test "read_cascade rejects a manage-cap for a DIFFERENT agent (instance-scoped gate)", %{
    workspace: workspace
  } do
    target = Ezagent.URI.entity(:team_alpha, :agent, "tgt-#{System.unique_integer([:positive])}")
    other = Ezagent.URI.entity(:team_alpha, :agent, "oth-#{System.unique_integer([:positive])}")
    other_manager = grant_manage_cap(other, workspace)

    # Holds Manage over `other`, reads `target` → must be denied (instance bind).
    assert {:error, :unauthorized} =
             Config.read_cascade(target, other_manager.uri, other_manager.caps)

    refute kind_live?(target)
  end

  defp kind_live?(uri) do
    match?({:ok, _pid}, Ezagent.KindRegistry.lookup(URI.to_string(uri)))
  end

  defp grant_manage_cap(agent, workspace) do
    manager = Ezagent.URI.entity(:team_alpha, :user, "mgr-#{System.unique_integer([:positive])}")
    requested = CreatorGrant.manage_cap(:agent, agent, workspace, manager)
    authority = install_test_authority!(agent, :agent)
    cap = authority_signed_cap!(authority, manager, requested)
    {:ok, _} = Ezagent.Users.create_read_only(manager, [self_license_cap!(manager)])
    %{uri: manager, caps: MapSet.new([cap])}
  end
end
