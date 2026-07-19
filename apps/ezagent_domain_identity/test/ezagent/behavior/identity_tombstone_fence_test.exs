defmodule Ezagent.ActionSet.IdentityTombstoneFenceTest do
  @moduledoc """
  task #180 (delete = atomic revocation), acceptance criterion 2 — the
  spawn/activate FENCE invariant tests.

  The earlier demand-spawn guard lived in the identity app's `entity://`
  SpawnRegistry fn and was DEAD: `SpawnRegistry.register/2` is last-wins
  and the session app boots after identity, overwriting it with an
  unguarded fn (dropped in commit 788743d68). The fence therefore lives
  in `Ezagent.ActionSet.Identity`'s Lifecycle callbacks (`create/1` +
  `activate/2`) — the one chokepoint EVERY User/Agent Kind start must
  pass, regardless of which spawn fn won registration or which entry
  point (demand-spawn / boot Loader / ensure_live / token-auth / login)
  triggered the spawn.

  These tests FAIL if the fence is removed: without it, a tombstoned
  user's Kind spawns again (the resurrection-via-respawn vector).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Identity
  alias Ezagent.Users

  @admin "entity://system/user/admin"

  defp tombstone_user(tag) do
    uri = "entity://team-alpha/user/fence-#{tag}-#{System.unique_integer([:positive])}"
    {:ok, _} = Users.create(uri, "pw", [])
    {:ok, _} = Users.disable(uri, @admin, "offboarding")
    {:ok, _} = Users.tombstone(uri, @admin, "gone")
    uri
  end

  describe "spawn fence (create/1 — fresh spawn path)" do
    test "a tombstoned user cannot be re-spawned via Ezagent.Kind.spawn" do
      uri = tombstone_user("kindspawn")
      parsed = Ezagent.URI.new!(uri)

      assert {:error, reason} =
               Ezagent.Kind.spawn(Ezagent.Entity.User, %{
                 uri: parsed,
                 initial_caps: []
               })

      assert inspect(reason) =~ "tombstoned",
             "expected the tombstone fence in the spawn failure, got: #{inspect(reason)}"

      # And no Kind came up anyway.
      assert Ezagent.KindRegistry.lookup(parsed) == :error
    end

    test "a tombstoned user cannot be re-spawned via SpawnRegistry (demand-spawn path)" do
      uri = tombstone_user("registry")
      parsed = Ezagent.URI.new!(uri)

      assert {:error, reason} = Ezagent.SpawnRegistry.spawn(parsed)

      assert inspect(reason) =~ "tombstoned",
             "expected the tombstone fence in the spawn failure, got: #{inspect(reason)}"

      assert Ezagent.KindRegistry.lookup(parsed) == :error
    end

    test "Identity.create/1 refuses a tombstoned user (unit)" do
      uri = tombstone_user("create")

      assert_raise RuntimeError, ~r/tombstoned user/, fn ->
        Identity.create(%{uri: Ezagent.URI.new!(uri)})
      end
    end

    test "Identity.create/1 still allows an ACTIVE user (guard is not a blanket denial)" do
      uri = "entity://team-alpha/user/fence-active-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "pw", [])

      assert {:ok, %{caps: _}} = Identity.create(%{uri: Ezagent.URI.new!(uri)})
    end

    test "Identity.create/1 allows a user with no provisioning row (absence is not deletion)" do
      uri = "entity://team-alpha/user/fence-norow-#{System.unique_integer([:positive])}"

      assert {:ok, %{caps: _}} = Identity.create(%{uri: Ezagent.URI.new!(uri)})
    end
  end

  describe "activate fence (rehydrate path — snapshot survived the destroy)" do
    test "Identity.activate/2 refuses a tombstoned user (unit)" do
      uri = tombstone_user("activate")

      assert_raise RuntimeError, ~r/tombstoned user/, fn ->
        Identity.activate(%{caps: MapSet.new()}, %{self_uri: Ezagent.URI.new!(uri)})
      end
    end

    test "Identity.activate/2 still reconciles an ACTIVE user" do
      uri = "entity://team-alpha/user/fence-actok-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "pw", [])

      assert {:ok, _transients} =
               Identity.activate(%{caps: MapSet.new()}, %{self_uri: Ezagent.URI.new!(uri)})
    end
  end

  describe "agent-owner fence" do
    test "an agent whose recorded owner is tombstoned cannot be created (unit)" do
      owner = tombstone_user("agentowner")

      agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/fence-owned-#{System.unique_integer([:positive])}"
        )

      :ok = Ezagent.AgentLineage.record(agent_uri, owner)

      assert_raise RuntimeError, ~r/owner is tombstoned/, fn ->
        Identity.create(%{uri: agent_uri})
      end
    end

    test "an agent whose owner is ACTIVE is unaffected" do
      owner = "entity://team-alpha/user/fence-owner-ok-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(owner, "pw", [])

      agent_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/fence-owned-ok-#{System.unique_integer([:positive])}"
        )

      :ok = Ezagent.AgentLineage.record(agent_uri, owner)

      assert {:ok, %{caps: _}} = Identity.create(%{uri: agent_uri})
    end
  end
end
