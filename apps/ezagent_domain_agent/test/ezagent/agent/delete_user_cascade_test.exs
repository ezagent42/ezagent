defmodule Ezagent.Agent.DeleteUserCascadeTest do
  @moduledoc """
  task #180 / #1469 (delete = atomic revocation, Part 2) — the OWNED-AGENT
  AUTHORITY CASCADE invariant tests. These ARE the completeness proof the
  plan's acceptance section requires:

    1. **Headline cascade invariant** — after `delete_user(U)`, an agent
       owned by U CANNOT authenticate (PAT rejected), CANNOT dispatch
       (caps cleared), and CANNOT respawn (fenced + torn down). Fails
       before the cascade: the agent kept acting.
    2. **Nested lineage** — a grandchild agent (spawned by U's agent) is
       revoked too (via `AgentLineage.spawned_in_lineage?/3`).
    3. **Independent agent NOT killed** — an agent in the same workspace
       whose authority is NOT derived from U is UNAFFECTED: the cascade
       is scoped to U-derived authority, not "all agents near U".
    4. **Cascade atomicity (F4)** — a failed per-agent teardown yields a
       retryable non-success and the retry converges.

  The cascade lives in `Ezagent.Identity.Offboarding` and runs inside
  `Users.tombstone/3`, so every `delete_user` path gets it.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_fixture_cap!: 5]

  alias Ezagent.Identity.AgentTombstone
  alias Ezagent.Users

  @admin "entity://system/user/admin"

  defp create_user(tag) do
    uri = "entity://team-alpha/user/casc-#{tag}-#{System.unique_integer([:positive])}"
    {:ok, _} = Users.create(uri, "pw", [])
    Ezagent.URI.new!(uri)
  end

  defp delete_user(user_uri) do
    {:ok, _} = Users.disable(user_uri, @admin, "offboarding")
    Users.tombstone(user_uri, @admin, "gone")
  end

  # Spawn a live Agent Kind with `creator_uri: owner` (the durable api_keys
  # slice creator) + a recorded lineage edge — the two ownership channels
  # the cascade enumerates.
  defp spawn_owned_agent(owner_uri, tag) do
    agent_uri =
      Ezagent.URI.agent("team-alpha", "casc-#{tag}-#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: agent_uri,
        creator_uri: owner_uri,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.AgentLineage.record(agent_uri, owner_uri)
    {agent_uri, pid}
  end

  defp mint_pat(agent_uri) do
    {plain, _row} = Ezagent.Entity.Token.mint(agent_uri, label: "svc")
    plain
  end

  describe "1. headline cascade invariant" do
    test "after delete_user(U) an owned agent cannot authenticate, dispatch, or respawn" do
      owner = create_user("headline")
      {agent_uri, agent_pid} = spawn_owned_agent(owner, "headline")

      # The agent holds real authority pre-delete: a PAT + a durable
      # signed cap + a per-Kind signing authority.
      plain = mint_pat(agent_uri)
      assert {:ok, _} = Ezagent.Entity.Token.authenticate(plain)

      cap =
        signed_fixture_cap!(agent_uri, :agent, Ezagent.ActionSet.Identity, :list_caps, agent_uri)

      :ok = Ezagent.EntityCaps.grant(agent_uri, cap)
      assert Enum.any?(Ezagent.EntityCaps.load_persisted(agent_uri), &(&1 == cap))

      # Offboard the owner.
      assert {:ok, _} = delete_user(owner)

      # CANNOT authenticate — the PAT is revoked AND the principal is
      # tombstoned (defense in depth).
      assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(plain)
      assert Ezagent.Entity.Token.list(agent_uri) == []

      # CANNOT dispatch — every durable cap is cleared (the snapshot with
      # its :identity slice is destroyed) and no live identity remains to
      # source caps from.
      assert Ezagent.EntityCaps.load_persisted(agent_uri) == []
      assert Ezagent.Identity.list_caps_for(agent_uri) == MapSet.new()

      # CANNOT respawn — tombstoned marker + fence on every spawn path;
      # the live process was torn down.
      assert AgentTombstone.tombstoned?(agent_uri)
      refute Process.alive?(agent_pid)
      assert Ezagent.KindRegistry.lookup(agent_uri) == :error

      assert {:error, reason} = Ezagent.SpawnRegistry.spawn(agent_uri)
      assert inspect(reason) =~ "principal_tombstoned"

      assert {:error, _} = Ezagent.SpawnRegistry.ensure_live(agent_uri)

      # The per-Kind signing authority is retired (no new caps can be
      # signed by this Kind again).
      assert Ezagent.Ecto.KindCapAuthority.active(URI.to_string(agent_uri)) == nil

      # The user's own revocation still holds.
      assert Users.deleted?(owner)
    end

    test "an agent owned via creator_uri WITHOUT a lineage row is still cascaded" do
      owner = create_user("owneronly")
      {agent_uri, _pid} = spawn_owned_agent(owner, "owneronly")
      # Sever the lineage channel: the creator_uri record alone must suffice.
      :ok = Ezagent.AgentLineage.forget(agent_uri)

      plain = mint_pat(agent_uri)

      assert {:ok, _} = delete_user(owner)

      assert AgentTombstone.tombstoned?(agent_uri)
      assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(plain)
      assert {:error, _} = Ezagent.SpawnRegistry.spawn(agent_uri)
    end
  end

  describe "2. nested lineage" do
    test "a grandchild agent (spawned by the user's agent) is revoked too" do
      owner = create_user("nested")
      {parent_uri, _parent_pid} = spawn_owned_agent(owner, "parent")
      {child_uri, child_pid} = spawn_owned_agent(parent_uri, "child")

      # Sanity: the grandchild is in the owner's lineage, not directly owned.
      assert Ezagent.AgentLineage.spawned_in_lineage?(child_uri, owner)

      plain = mint_pat(child_uri)
      assert {:ok, _} = Ezagent.Entity.Token.authenticate(plain)

      assert {:ok, _} = delete_user(owner)

      # Parent AND grandchild are both tombstoned.
      assert AgentTombstone.tombstoned?(parent_uri)
      assert AgentTombstone.tombstoned?(child_uri)
      assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(plain)
      refute Process.alive?(child_pid)
      assert {:error, _} = Ezagent.SpawnRegistry.spawn(child_uri)
      assert {:error, _} = Ezagent.SpawnRegistry.spawn(parent_uri)
    end
  end

  describe "3. independent agent NOT killed (cascade is scoped)" do
    test "an agent in the same workspace NOT derived from U is fully unaffected" do
      owner = create_user("scoped")
      other_owner = create_user("independent")
      {agent_uri, agent_pid} = spawn_owned_agent(other_owner, "unaffected")

      plain = mint_pat(agent_uri)

      cap =
        signed_fixture_cap!(agent_uri, :agent, Ezagent.ActionSet.Identity, :list_caps, agent_uri)

      :ok = Ezagent.EntityCaps.grant(agent_uri, cap)

      # Delete the UNRELATED user in the same workspace.
      assert {:ok, _} = delete_user(owner)

      # The independent agent keeps EVERYTHING: not tombstoned, process
      # alive, PAT authenticates, caps intact, spawn paths work.
      refute AgentTombstone.tombstoned?(agent_uri)
      assert Process.alive?(agent_pid)
      assert {:ok, _} = Ezagent.Entity.Token.authenticate(plain)
      assert Enum.any?(Ezagent.EntityCaps.load_persisted(agent_uri), &(&1 == cap))
      assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(agent_uri)
    end

    test "an agent owned by a tombstoned user in a DIFFERENT workspace is still cascaded (global sweep)" do
      owner = create_user("global")
      # An agent the user spawned into ANOTHER workspace (lineage crosses
      # workspaces — the sweep must not bound to the user's home tenant).
      foreign_agent =
        Ezagent.URI.agent("team-beta", "casc-global-#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
          uri: foreign_agent,
          creator_uri: owner,
          initial_caps: MapSet.new()
        })

      :ok = Ezagent.AgentLineage.record(foreign_agent, owner)

      assert {:ok, _} = delete_user(owner)

      assert AgentTombstone.tombstoned?(foreign_agent)
      assert {:error, _} = Ezagent.SpawnRegistry.spawn(foreign_agent)
    end
  end

  describe "4. cascade atomicity (F4)" do
    test "a failed per-agent teardown yields a retryable non-success; the retry converges" do
      owner = create_user("atomic")
      {agent_uri, _pid} = spawn_owned_agent(owner, "atomic")
      agent_key = URI.to_string(agent_uri)

      # Remove the live process, then register the TEST PROCESS as the
      # agent's live Kind — `Lifecycle.destroy/2`'s self-destroy guard
      # fails the per-agent teardown deterministically.
      :ok = Ezagent.Kind.terminate(agent_uri)
      wait_until(fn -> Ezagent.KindRegistry.lookup(agent_uri) == :error end)
      :ok = Ezagent.KindRegistry.put_new(agent_key, self())
      on_exit(fn -> Registry.unregister(Ezagent.KindRegistry, agent_key) end)

      # The delete reports FAILURE (never a false success) — but the
      # durable state is fail-CLOSED: the user is tombstoned AND the
      # agent's marker + PAT revocation are already committed.
      assert {:error, {:agent_teardown_failed, ^agent_uri, :cannot_self_destroy}} =
               delete_user(owner)

      assert Users.deleted?(owner)
      assert AgentTombstone.tombstoned?(agent_uri)
      # The agent is fenced even with its teardown outstanding.
      assert {:error, _} = Ezagent.SpawnRegistry.spawn(agent_uri)

      # Remove the failure cause; the idempotent retry converges.
      Registry.unregister(Ezagent.KindRegistry, agent_key)
      assert {:ok, _} = Users.tombstone(owner, @admin, "gone")
      assert Ezagent.Ecto.KindSnapshot.get(agent_key) == nil
    end
  end

  describe "5. recipe-cap binding + signing authority revocation" do
    test "the agent's durable recipe binding is tombstoned (no re-grant on respawn)" do
      owner = create_user("recipe")
      {agent_uri, _pid} = spawn_owned_agent(owner, "recipe")

      proposal =
        Ezagent.Capability.cap(
          :agent,
          Ezagent.ActionSet.Identity,
          :list_caps,
          agent_uri,
          Ezagent.URI.workspace("team-alpha")
        )

      {:ok, %{caps: _}} =
        Ezagent.Identity.RecipeCapBinding.issue_and_upsert(
          agent_uri,
          "cascade-test-recipe",
          Ezagent.Entity.User.admin_uri(),
          [proposal]
        )

      assert {:ok, _} = Ezagent.Identity.RecipeCapBinding.fetch(agent_uri)

      assert {:ok, _} = delete_user(owner)

      # The binding is tombstoned — a respawn could never re-grant the
      # recipe caps (the fence blocks the respawn anyway; this is the
      # durable-cap-store half of "clear the agent's SIGNED caps").
      assert :not_found = Ezagent.Identity.RecipeCapBinding.fetch(agent_uri)
    end
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: raise("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
