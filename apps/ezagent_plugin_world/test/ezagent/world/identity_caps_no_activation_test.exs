defmodule Ezagent.World.IdentityCapsNoActivationTest do
  @moduledoc """
  FP5 S5 (#115) regression for the world caps DETAIL surface.

  `Ezagent.World.IdentityData` rendered an entity's granted caps by dispatching
  `identity.list_caps` (`:call`), which lazy-spawns + force-activates a cold
  agent — a cold `cc` agent needs >5s to launch claude, blowing the ReadyGate
  budget → the caps panel showed `:activate_timeout`. The fix reads the entity's
  caps from the durable IdentityCaps Store WITHOUT activation, after preserving
  the caller gate.

  This test seeds the authoritative Store for a COLD agent (Kind never spawned)
  and asserts the caps render from durable state AND the agent is never activated, plus the
  caller gate still rejects an uncapped caller.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.IdentityData

  setup do
    name = "caps-cold-#{System.unique_integer([:positive])}"
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)
    workspace = Ezagent.Capability.workspace_of(agent)

    # A real granted cap on the agent's identity slice, traceable to a real
    # entity so `granted_by_entity?/1` holds when rendered.
    granter = Ezagent.URI.entity(:team_alpha, :user, "granter")

    requested =
      Ezagent.Capability.cap(
        :agent,
        Ezagent.ActionSet.Chat,
        :send,
        agent,
        workspace
      )

    self_license = Ezagent.Test.CapHelper.self_license_cap!(agent, :agent)

    cap =
      Ezagent.Test.CapHelper.with_test_authority(agent, :agent, fn authority ->
        Ezagent.Test.CapHelper.authority_signed_cap!(authority, agent, requested)
      end)

    # Persist the sole authoritative capability carrier. NO Ezagent.Kind.spawn
    # → the agent remains cold while the read resolves durable state.
    :ok = Ezagent.IdentityCaps.Store.initialize(agent, [self_license, cap])

    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent))

    %{agent: agent, granter: granter}
  end

  test "entity caps render from the Store WITHOUT activating the cold agent", %{agent: agent} do
    admin = Ezagent.URI.user(:system, :admin)

    admin_caps =
      MapSet.new([
        Ezagent.Test.CapHelper.signed_fixture_cap!(
          agent,
          :agent,
          Ezagent.ActionSet.Identity,
          :list_caps,
          admin
        )
      ])

    state =
      IdentityData.state_for(
        %{
          component: "entity_caps",
          title: "Caps",
          path: "/identities/caps",
          entity_uri: agent
        },
        %{workspace_uri: nil, caller_uri: admin, caller_caps: admin_caps}
      )

    caps = state["caps"]
    assert is_list(caps), "expected the Store caps list, got #{inspect(caps)}"
    assert Enum.any?(caps, &(&1["behavior"] =~ "Chat" and &1["action"] == ":send"))

    # THE INVARIANT: rendering the caps did NOT start the agent Kind.
    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent)),
           "list_entity_caps activated the agent — it must snapshot-read, not dispatch"
  end

  test "entity caps reject an uncapped caller without activating", %{agent: agent} do
    state =
      IdentityData.state_for(
        %{
          component: "entity_caps",
          title: "Caps",
          path: "/identities/caps",
          entity_uri: agent
        },
        %{workspace_uri: nil, caller_uri: nil, caller_caps: MapSet.new()}
      )

    # Unauthorized → graceful error map (the SAME shape the dispatch denial gave).
    assert %{"error" => _} = state["caps"]
    assert :error = Ezagent.KindRegistry.lookup(URI.to_string(agent))
  end
end
