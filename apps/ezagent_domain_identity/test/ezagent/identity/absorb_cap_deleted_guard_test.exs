defmodule Ezagent.Identity.AbsorbCapDeletedGuardTest do
  @moduledoc """
  task #180 (delete = atomic revocation), acceptance criterion 3 — the
  `absorb_cap` deleted-recipient guard invariant tests.

  A `:absorb_cap` delivery is DURABLE (`cap_delivery_outbox`): an envelope
  enqueued while a user was alive can be replayed after the user was
  tombstoned and — without these guards — would re-store the revoked cap
  (resurrection). Two layers, both covered here:

    1. `Users.tombstone/3` dead-letters every PENDING outbox row targeting
       the user, atomically with the tombstone itself.
    2. `IdentityAdmin.handle_absorb_cap/2` refuses a tombstoned recipient
       (`{:error, :user_deleted}` — classified PERMANENT by the outbox so
       the replay dead-letters), the backstop for the commit→destroy window.

  These tests FAIL if either guard is removed.
  """

  use EzagentCore.DataCase, async: false

  import Ecto.Query
  import Ezagent.Test.CapHelper, only: [signed_fixture_cap!: 5]

  alias Ezagent.ActionSet.IdentityAdmin
  alias Ezagent.Cap.Delivery
  alias Ezagent.Cap.DeliveryOutbox
  alias Ezagent.Users
  alias EzagentCore.Repo

  @admin "entity://system/user/admin"

  defp unique_user(tag) do
    Ezagent.URI.user("team-alpha", "absorb-del-#{tag}-#{System.unique_integer([:positive])}")
  end

  defp artifact_for(user_uri) do
    signed_fixture_cap!(user_uri, :user, Ezagent.ActionSet.Identity, :list_caps, user_uri)
  end

  defp pending_delivery_for(user_uri) do
    Repo.one!(
      from(delivery in Delivery,
        where: delivery.target_uri == ^URI.to_string(user_uri),
        where: delivery.op == :absorb_cap
      )
    )
  end

  describe "tombstone dead-letters pending absorb_cap deliveries" do
    test "a pending absorb_cap is dead-lettered at tombstone time and can never replay" do
      user_uri = unique_user("pending")
      {:ok, _} = Users.create(user_uri, "pw", [])

      # Enqueue while the user is ALIVE but never spawned (no snapshot →
      # the first attempt lands `:no_such_actor`, transient → stays pending).
      artifact = artifact_for(user_uri)
      assert :ok = Ezagent.Identity.absorb_cap(user_uri, artifact)

      delivery = pending_delivery_for(user_uri)
      assert delivery.status == :pending

      # Operator offboards: disable → delete.
      {:ok, _} = Users.disable(user_uri, @admin, "offboarding")
      assert {:ok, _} = Users.tombstone(user_uri, @admin, "gone")

      # The pending row was dead-lettered ATOMICALLY with the tombstone.
      reloaded = Repo.get!(Delivery, delivery.id)
      assert reloaded.status == :dead
      assert reloaded.dead_at != nil
      assert reloaded.last_error =~ "user_deleted"

      # Nothing replays post-delete: an explicit attempt refuses.
      assert {:error, :delivery_dead} = DeliveryOutbox.attempt(delivery.id)

      # And no cap was resurrected anywhere durable.
      assert Users.get_by_uri(user_uri).caps == []
      assert Ezagent.EntityCaps.load_persisted(user_uri) == []
    end

    test "the idempotent tombstone retry also dead-letters a newly pending row" do
      user_uri = unique_user("retry")
      {:ok, _} = Users.create(user_uri, "pw", [])
      {:ok, _} = Users.disable(user_uri, @admin, "offboarding")
      assert {:ok, _} = Users.tombstone(user_uri, @admin, "gone")

      # A stray envelope lands AFTER the first tombstone (racing producer).
      artifact = artifact_for(user_uri)
      assert :ok = Ezagent.Identity.absorb_cap(user_uri, artifact)
      delivery = pending_delivery_for(user_uri)
      assert delivery.status == :pending

      # The retry branch re-asserts the full revocation, including the
      # outbox cancel.
      assert {:ok, _} = Users.tombstone(user_uri, @admin, "gone")
      assert Repo.get!(Delivery, delivery.id).status == :dead
    end
  end

  describe "handle_absorb_cap deleted-recipient guard" do
    test "an absorb_cap replayed to a tombstoned user is rejected and stores no cap" do
      user_uri = unique_user("replay")
      {:ok, _} = Users.create(user_uri, "pw", [])
      {:ok, _} = Users.disable(user_uri, @admin, "offboarding")
      {:ok, _} = Users.tombstone(user_uri, @admin, "gone")

      artifact = artifact_for(user_uri)

      ctx = %{
        caller: :vm_internal,
        self_uri: user_uri,
        read: fn _key, default -> default end
      }

      assert {:error, :user_deleted} =
               IdentityAdmin.handle_absorb_cap(%{artifact: artifact}, ctx)

      # Fail-closed: NOTHING was stored, durable or otherwise.
      assert Users.get_by_uri(user_uri).caps == []
      assert Ezagent.EntityCaps.load_persisted(user_uri) == []
    end

    test "an absorb_cap to an ACTIVE user still stores (guard is not a blanket denial)" do
      user_uri = unique_user("active")
      {:ok, _} = Users.create(user_uri, "pw", [])

      artifact = artifact_for(user_uri)

      ctx = %{
        caller: :vm_internal,
        self_uri: user_uri,
        read: fn
          :caps, _default -> MapSet.new()
          _key, default -> default
        end
      }

      assert {:ok, %{caps: caps}, _effects} =
               IdentityAdmin.handle_absorb_cap(%{artifact: artifact}, ctx)

      assert Enum.member?(caps, artifact)
    end
  end
end
