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

  describe "F1-a — the no-Identity-behavior hole (behaviors: [])" do
    test "a tombstoned user is refused even when spawned with an Identity-less behavior set" do
      uri = tombstone_user("nobehaviors")
      parsed = Ezagent.URI.new!(uri)

      # The C2 Lifecycle fence lives in Identity.create/activate — a Kind
      # spawned with an explicit behavior set EXCLUDING Identity never runs
      # it. The behavior-set-independent `Ezagent.SpawnFence` (consulted by
      # `Kind.Server.init/1` before the snapshot load) must refuse anyway.
      assert {:error, reason} =
               Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: parsed, behaviors: []})

      assert inspect(reason) =~ "principal_tombstoned",
             "expected the spawn fence in the spawn failure, got: #{inspect(reason)}"

      assert Ezagent.KindRegistry.lookup(parsed) == :error
    end
  end

  describe "F1-b — the already-running hole (registry return)" do
    test "a tombstoned user whose process is still live is REFUSED + TORN DOWN, not returned" do
      # Live, ACTIVE user's Kind (the process the race leaves behind: the
      # tombstone lands while the Kind is still running).
      uri = "entity://team-alpha/user/fence-live-#{System.unique_integer([:positive])}"
      {:ok, _} = Users.create(uri, "pw", [])
      parsed = Ezagent.URI.new!(uri)
      {:ok, pid} = Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: parsed, initial_caps: []})
      assert Process.alive?(pid)

      # The tombstone commits with NO teardown yet (the exact commit→teardown
      # window codex F1-b names): mark the row directly, leave the process up.
      mark_deleted!(uri)

      # ensure_live's already-live return is fenced + the stale process is
      # torn down (never reported `{:ok, :live}`).
      assert {:error, reason0} = Ezagent.SpawnRegistry.ensure_live(parsed)
      assert inspect(reason0) =~ "principal_tombstoned"
      wait_until(fn -> not Process.alive?(pid) end)

      # The already-running registry return must REFUSE (never hand the pid
      # back) — with the process now gone, this also exercises the
      # spawn-half refusal.
      assert {:error, reason} = Ezagent.SpawnRegistry.spawn(parsed)

      assert inspect(reason) =~ "principal_tombstoned",
             "expected the spawn fence in the spawn failure, got: #{inspect(reason)}"

      assert Ezagent.KindRegistry.lookup(parsed) == :error
    end
  end

  describe "F1-c — the direct-parent-only hole (full-chain lineage walk)" do
    test "an agent whose GRANDPARENT user is tombstoned is refused (nested lineage)" do
      owner = tombstone_user("grandowner")

      parent_agent =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/fence-parent-#{System.unique_integer([:positive])}"
        )

      child_agent =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/fence-child-#{System.unique_integer([:positive])}"
        )

      # Lineage: owner (user, tombstoned) → parent_agent → child_agent.
      # The direct-parent-only check saw child's parent (an AGENT, not a
      # tombstoned user) and ADMITTED the spawn; the full-chain walk must refuse.
      :ok = Ezagent.AgentLineage.record(parent_agent, owner)
      :ok = Ezagent.AgentLineage.record(child_agent, parent_agent)

      assert_raise RuntimeError, ~r/tombstoned/, fn ->
        Identity.create(%{uri: child_agent})
      end
    end
  end

  # Mark the users row deleted DIRECTLY (bypassing `Users.tombstone/3`'s
  # teardown) — the deterministic form of "tombstone committed while the
  # Kind process is still live" for the F1-b registry-return test.
  defp mark_deleted!(uri_str) do
    row = Repo.get_by!(Users, uri: uri_str)
    now = DateTime.utc_now()

    row
    |> Ecto.Changeset.change(%{
      deleted_at: now,
      deleted_by: "entity://system/user/admin",
      deleted_reason: "fence-race simulation",
      disabled_at: row.disabled_at || now,
      disabled_by: row.disabled_by || "entity://system/user/admin"
    })
    |> Repo.update!()
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
