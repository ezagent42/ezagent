defmodule Ezagent.ActionSet.RecipeCapBindingLifecycleTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Identity
  alias Ezagent.Identity.RecipeCapBinding

  @admin Ezagent.Entity.User.admin_uri()

  setup do
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(@admin)
    :ok = Ezagent.ReadyGate.await(@admin, 5_000)
    :ok
  end

  defp agent_uri do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/binding-lifecycle-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})

    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp proposal(agent_uri, action) do
    Ezagent.Capability.cap(
      :agent,
      Ezagent.ActionSet.Sandbox,
      action,
      Ezagent.URI.instance(agent_uri),
      Ezagent.Capability.workspace_of(agent_uri)
    )
  end

  defp identity_list_proposal(agent_uri) do
    Ezagent.Capability.cap(
      :agent,
      Identity,
      :list_caps,
      Ezagent.URI.instance(agent_uri),
      Ezagent.Capability.workspace_of(agent_uri)
    )
  end

  defp recipe_caps(state) do
    Enum.filter(state.caps, &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :read))
  end

  defp assert_unique_identity_keys(state) do
    keys = Enum.map(state.caps, &Ezagent.Capability.identity_key/1)
    assert length(keys) == MapSet.size(MapSet.new(keys))
  end

  test "create self-stores the pre-issued binding with issuer provenance" do
    agent_uri = agent_uri()

    assert {:ok, %{version: version}} =
             RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "reader",
               @admin,
               [proposal(agent_uri, :read)]
             )

    assert {:ok, state} = Identity.create(%{uri: agent_uri})
    assert state.recipe_binding_version == version
    assert MapSet.size(state.recipe_binding_keys) == 1

    assert [stored] = recipe_caps(state)
    assert stored.granted_by == @admin
    assert Ezagent.Cap.storable_for?(stored, agent_uri)
    assert is_binary(stored.signature)
    assert is_binary(stored.key_id)
  end

  test "activate self-heals a raced binding once without duplicates" do
    agent_uri = agent_uri()
    assert {:ok, before_binding} = Identity.create(%{uri: agent_uri})
    assert recipe_caps(before_binding) == []

    assert {:ok, %{version: version}} =
             RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "reader",
               @admin,
               [proposal(agent_uri, :read), proposal(agent_uri, :read)]
             )

    assert {:ok, %{}, healed} =
             Identity.activate(before_binding, %{self_uri: agent_uri})

    assert healed.recipe_binding_version == version
    assert length(recipe_caps(healed)) == 1
    assert {:ok, %{}} = Identity.activate(healed, %{self_uri: agent_uri})
  end

  test "sync_live installs a binding created after the target Kind is live" do
    agent_uri = agent_uri()

    refute Enum.any?(
             Ezagent.Identity.list_caps_for(agent_uri),
             &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :read)
           )

    assert {:ok, %{version: version}} =
             RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "reader",
               @admin,
               [proposal(agent_uri, :read)]
             )

    assert :ok = RecipeCapBinding.sync_live(agent_uri)

    assert [stored] =
             Enum.filter(
               Ezagent.Identity.list_caps_for(agent_uri),
               &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :read)
             )

    assert stored.grantee_uri == agent_uri

    assert {:ok, identity_slice} = Ezagent.Kind.read(agent_uri, :identity, spawn: :never)
    identity = Ezagent.Kind.normalize_slice_view(identity_slice)
    assert identity.recipe_binding_version == version
  end

  test "same binding version does not resurrect a deliberately revoked cap" do
    agent_uri = agent_uri()

    assert {:ok, %{version: version}} =
             RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "reader",
               @admin,
               [proposal(agent_uri, :read)]
             )

    assert {:ok, state} = Identity.create(%{uri: agent_uri})
    assert state.recipe_binding_version == version

    revoked = %{state | caps: MapSet.new(Enum.reject(state.caps, &(&1.action == :read)))}
    assert recipe_caps(revoked) == []
    assert {:ok, %{}} = Identity.activate(revoked, %{self_uri: agent_uri})
  end

  test "new binding version replaces old binding-owned keys" do
    agent_uri = agent_uri()

    assert {:ok, %{version: 1}} =
             RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "reader",
               @admin,
               [proposal(agent_uri, :read)]
             )

    assert {:ok, state_v1} = Identity.create(%{uri: agent_uri})
    assert length(recipe_caps(state_v1)) == 1

    assert {:ok, %{version: 2}} =
             RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "reader",
               @admin,
               [proposal(agent_uri, :destroy)]
             )

    assert {:ok, %{}, state_v2} = Identity.activate(state_v1, %{self_uri: agent_uri})
    assert_unique_identity_keys(state_v2)

    refute Enum.any?(
             state_v2.caps,
             &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :read)
           )

    assert Enum.any?(
             state_v2.caps,
             &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :destroy)
           )
  end

  test "tombstone removes binding-owned caps from a persisted identity state" do
    agent_uri = agent_uri()

    assert {:ok, %{version: version}} =
             RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "reader",
               @admin,
               [proposal(agent_uri, :read)]
             )

    assert {:ok, state} = Identity.create(%{uri: agent_uri})
    assert :ok = RecipeCapBinding.tombstone_if_version(agent_uri, version)

    assert {:ok, %{}, cleared} = Identity.activate(state, %{self_uri: agent_uri})
    assert recipe_caps(cleared) == []
    assert_unique_identity_keys(cleared)
    refute Map.has_key?(cleared, :recipe_binding_version)
    refute Map.has_key?(cleared, :recipe_binding_keys)
  end

  test "clearing an overlapping binding does not resurrect an unsigned structural default" do
    agent_uri = agent_uri()

    assert {:ok, %{version: version}} =
             RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "identity-reader",
               @admin,
               [identity_list_proposal(agent_uri)]
             )

    assert {:ok, state} = Identity.create(%{uri: agent_uri})

    assert Enum.count(state.caps, &(&1.behavior == Identity and &1.action == :list_caps)) == 1

    assert :ok = RecipeCapBinding.tombstone_if_version(agent_uri, version)
    assert {:ok, %{}, cleared} = Identity.activate(state, %{self_uri: agent_uri})

    assert_unique_identity_keys(cleared)
    assert Enum.count(cleared.caps, &(&1.behavior == Identity and &1.action == :list_caps)) == 0
  end
end
