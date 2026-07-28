defmodule Ezagent.EntityCaps.StoreTest do
  @moduledoc """
  #189 PR-1 — unit tests for the unified per-entity identity-caps store
  (cutover step 1, ADDITIVE): round-trip, dual-write parity vs the legacy
  stores, status transitions, tombstone, and the provisioning-receipt API.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.{Capability, EntityCaps, SnapshotStore}
  alias Ezagent.EntityCaps.{Store, UserStore}
  alias Ezagent.Identity.ProvisioningReceipt

  @workspace URI.new!("workspace://identity-caps-store")
  @issuer URI.new!("entity://identity-caps-store/user/issuer")

  defmodule IdentityHostKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :agent

    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.IdentityAdmin]

    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  defmodule EphemeralHostKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :agent

    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.IdentityAdmin]

    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = Ezagent.ReadyGate.register_external_gate(Ezagent.EntityCapsReadyBarrier)
    :ok = Ezagent.EntityCapsReadyBarrier.clear()

    for action <- [:list_caps, :has_cap?, :persist_caps, :store_cap, :remove_cap] do
      :ok =
        Ezagent.CapabilityRegistry.register(
          IdentityHostKind,
          action,
          if(action in [:persist_caps, :store_cap, :remove_cap],
            do: Ezagent.ActionSet.IdentityAdmin,
            else: Ezagent.ActionSet.Identity
          )
        )
    end

    on_exit(&Ezagent.EntityCapsReadyBarrier.clear/0)
    :ok
  end

  describe "round-trip" do
    test "persist then load returns the complete cap set" do
      agent = agent_uri("round-trip")
      caps = licensed_caps(agent, [issued_cap(agent, :send), issued_cap(agent, :join)])

      assert :ok = Store.persist(agent, caps)
      assert identity_keys(Store.load(agent)) == identity_keys(caps)

      row = Store.fetch(agent)
      assert row.identity_status == "active"
      assert is_nil(row.provisioning_receipt)
      assert Store.has_row?(agent)
      assert Store.status(agent) == :active
    end

    test "persist upserts, preserving status and receipt" do
      agent = agent_uri("upsert")
      first = licensed_caps(agent, [issued_cap(agent, :send)])
      second = licensed_caps(agent, [issued_cap(agent, :join)])
      receipt = ProvisioningReceipt.issue(agent, @issuer, :provision)

      assert :ok = Store.provision(agent, first, receipt)
      assert :ok = Store.revoke_provisioning(agent)
      assert :ok = Store.persist(agent, second)

      row = Store.fetch(agent)
      assert row.identity_status == "revoked_unprovisioned"
      assert row.provisioning_receipt == ProvisioningReceipt.to_json(receipt)
      # A non-active row yields an empty holder set, never the stored caps.
      assert Store.load(agent) == []
    end

    test "update/2 transforms under the row lock and creates the row when absent" do
      agent = agent_uri("update")
      cap = issued_cap(agent, :send)

      refute Store.has_row?(agent)
      assert :ok = Store.update(agent, fn current -> {:ok, current ++ [cap]} end)
      assert cap_present?(Store.load(agent), cap)

      assert {:error, :boom} = Store.update(agent, fn _current -> {:error, :boom} end)
      assert cap_present?(Store.load(agent), cap)
    end

    test "fetch_durable_caps falls back only when no row exists" do
      agent = agent_uri("dual-read-shape")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])

      assert Store.fetch_durable_caps(agent) == :fallback

      assert :ok = Store.persist(agent, caps)
      assert {:ok, store_caps} = Store.fetch_durable_caps(agent)
      assert identity_keys(store_caps) == identity_keys(caps)

      assert :ok = Store.revoke_provisioning(agent)
      assert {:ok, []} = Store.fetch_durable_caps(agent)
    end
  end

  describe "status transitions + tombstone" do
    test "provision activates with receipt; revoke leaves revoked_unprovisioned" do
      agent = agent_uri("lifecycle")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])
      receipt = ProvisioningReceipt.issue(agent, @issuer, :provision)

      assert :ok = Store.provision(agent, caps, receipt)
      assert Store.status(agent) == :active
      assert identity_keys(Store.load(agent)) == identity_keys(caps)

      assert :ok = Store.revoke_provisioning(agent)
      assert Store.status(agent) == :revoked_unprovisioned
      assert Store.load(agent) == []

      # Idempotent.
      assert :ok = Store.revoke_provisioning(agent)
      assert Store.status(agent) == :revoked_unprovisioned
    end

    test "provision requires a valid :provision receipt bound to the subject" do
      agent = agent_uri("receipt-gate")
      other = agent_uri("receipt-gate-other")
      caps = licensed_caps(agent, [])

      assert {:error, :invalid_provisioning_receipt} =
               Store.provision(agent, caps, ProvisioningReceipt.issue(agent, @issuer, :reprovision))

      assert {:error, :invalid_provisioning_receipt} =
               Store.provision(agent, caps, ProvisioningReceipt.issue(other, @issuer, :provision))

      tampered =
        agent
        |> ProvisioningReceipt.issue(@issuer, :provision)
        |> Map.put(:nonce, "forged-nonce")

      assert {:error, :invalid_provisioning_receipt} = Store.provision(agent, caps, tampered)

      refute Store.has_row?(agent)
    end

    test "reprovision is the only way out of revoked_unprovisioned" do
      agent = agent_uri("reprovision")
      old_caps = licensed_caps(agent, [issued_cap(agent, :send)])
      new_caps = licensed_caps(agent, [issued_cap(agent, :join)])

      assert :ok = Store.provision(agent, old_caps, ProvisioningReceipt.issue(agent, @issuer, :provision))
      assert :ok = Store.revoke_provisioning(agent)

      assert {:error, :invalid_provisioning_receipt} =
               Store.reprovision(agent, new_caps, ProvisioningReceipt.issue(agent, @issuer, :provision))

      assert :ok =
               Store.reprovision(agent, new_caps, ProvisioningReceipt.issue(agent, @issuer, :reprovision))

      assert Store.status(agent) == :active
      assert identity_keys(Store.load(agent)) == identity_keys(new_caps)

      assert {:error, :already_active} =
               Store.reprovision(agent, new_caps, ProvisioningReceipt.issue(agent, @issuer, :reprovision))
    end

    test "tombstone is terminal without an authenticated reprovision" do
      agent = agent_uri("tombstone")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])

      assert :ok = Store.provision(agent, caps, ProvisioningReceipt.issue(agent, @issuer, :provision))
      assert :ok = Store.tombstone(agent)
      assert Store.status(agent) == :tombstoned
      assert Store.load(agent) == []

      # Monotone: no transition back except authenticated reprovision.
      assert {:error, :tombstoned} = Store.revoke_provisioning(agent)

      assert {:error, :tombstoned} =
               Store.provision(agent, caps, ProvisioningReceipt.issue(agent, @issuer, :provision))

      assert :ok =
               Store.reprovision(agent, caps, ProvisioningReceipt.issue(agent, @issuer, :reprovision))

      assert Store.status(agent) == :active
    end

    test "tombstone creates a row for a URI that never had one" do
      agent = agent_uri("tombstone-fresh")

      refute Store.has_row?(agent)
      assert :ok = Store.tombstone(agent)
      assert Store.status(agent) == :tombstoned
      assert Store.load(agent) == []
    end
  end

  describe "ProvisioningReceipt" do
    test "issue/verify round-trip and to_json/from_json round-trip" do
      agent = agent_uri("receipt")
      receipt = ProvisioningReceipt.issue(agent, @issuer, :provision)

      assert ProvisioningReceipt.verify(receipt)
      assert ProvisioningReceipt.valid_for?(receipt, agent, :provision)
      refute ProvisioningReceipt.valid_for?(receipt, agent, :reprovision)
      refute ProvisioningReceipt.valid_for?(receipt, agent_uri("receipt-other"), :provision)

      assert {:ok, decoded} = receipt |> ProvisioningReceipt.to_json() |> ProvisioningReceipt.from_json()
      assert decoded == receipt
      assert ProvisioningReceipt.verify(decoded)

      assert {:error, :invalid_receipt} = ProvisioningReceipt.from_json(nil)
      assert {:error, :invalid_receipt} = ProvisioningReceipt.from_json("not json")
      assert {:error, :invalid_receipt} = ProvisioningReceipt.from_json(~s({"transition": "bogus"}))
    end
  end

  describe "dual-write parity (users)" do
    test "UserStore writes mirror into the unified store in the same transaction" do
      user = user_uri("parity-user")
      first = issued_cap(user, :send)
      second = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, licensed_caps(user, [first]))
      # Users.create writes caps_json directly (not via UserStore), so the
      # mirror row appears at the first UserStore write.
      refute Store.has_row?(user)

      assert :ok = UserStore.persist(user, licensed_caps(user, [first, second]))

      assert identity_keys(Store.load(user)) ==
               identity_keys(UserStore.load(user))

      assert :ok = UserStore.update(user, fn caps -> {:ok, Enum.reject(caps, &(&1.action == :send))} end)

      assert identity_keys(Store.load(user)) == identity_keys(UserStore.load(user))
      refute cap_present?(Store.load(user), first)
    end

    test "load_persisted prefers the store row and falls back without one" do
      user = user_uri("dual-read-user")
      caps_json_cap = issued_cap(user, :send)
      store_cap = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, licensed_caps(user, [caps_json_cap]))

      # No store row yet → legacy fallback (users.caps_json).
      assert cap_present?(EntityCaps.load_persisted(user), caps_json_cap)

      # A store row exists → it is preferred over caps_json.
      assert :ok = Store.persist(user, licensed_caps(user, [store_cap]))
      assert cap_present?(EntityCaps.load_persisted(user), store_cap)
      refute cap_present?(EntityCaps.load_persisted(user), caps_json_cap)
    end
  end

  describe "dual-write parity (snapshot plane)" do
    test "direct SnapshotStore writes mirror into the unified store" do
      agent = agent_uri("parity-snapshot")
      cap = issued_cap(agent, :send)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [cap]))}}},
                 kind_type: :agent
               )

      assert Store.has_row?(agent)
      assert cap_present?(Store.load(agent), cap)
      assert cap_present?(EntityCaps.load_persisted(agent), cap)

      # The Kind.read_durable :identity projection is store-preferred.
      assert {:ok, %{caps: durable_caps}, _meta} = Ezagent.Kind.read_durable(agent, :identity)
      assert cap_present?(MapSet.to_list(durable_caps), cap)
    end

    test "SnapshotStore.delete clears the mirror row too" do
      agent = agent_uri("parity-delete")
      cap = issued_cap(agent, :send)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [cap]))}}},
                 kind_type: :agent
               )

      assert Store.has_row?(agent)

      assert :ok = SnapshotStore.delete(agent)
      refute Store.has_row?(agent)
      assert EntityCaps.load_persisted(agent) == []
    end

    test "a committed :identity mutation on a live Kind mirrors into the store" do
      agent = agent_uri("parity-commit")
      first = issued_cap(agent, :send)
      second = issued_cap(agent, :join)

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: [first]})

      wait_until_ready(agent)

      assert :ok = EntityCaps.grant(agent, second)

      assert Store.has_row?(agent)
      assert cap_present?(Store.load(agent), first)
      assert cap_present?(Store.load(agent), second)

      assert :ok = EntityCaps.revoke(agent, first)
      refute cap_present?(Store.load(agent), first)
      assert cap_present?(Store.load(agent), second)

      :ok = Ezagent.Kind.terminate(agent)
    end

    test "user URIs and ephemeral Kinds are not mirrored by the snapshot-plane hook" do
      user = user_uri("skip-user")
      cap = issued_cap(user, :send)

      assert :ok =
               Store.sync_committed_identity(user, nil, %{caps: MapSet.new(licensed_caps(user, [cap]))})

      refute Store.has_row?(user)

      agent = agent_uri("skip-ephemeral")

      assert :ok =
               Store.sync_committed_identity(agent, EphemeralHostKind, %{
                 caps: MapSet.new(licensed_caps(agent, [issued_cap(agent, :send)]))
               })

      refute Store.has_row?(agent)

      # The same slice on a durable Kind (or the direct-write path) mirrors.
      assert :ok =
               Store.sync_committed_identity(agent, nil, %{
                 state: %{caps: MapSet.new(licensed_caps(agent, [issued_cap(agent, :send)]))}
               })

      assert Store.has_row?(agent)
    end

    test "existence_signal? excludes users and absent rows" do
      agent = agent_uri("existence")
      user = user_uri("existence")

      refute Store.existence_signal?(agent)
      refute Store.existence_signal?(user)

      assert :ok = Store.persist(agent, [])
      assert :ok = Store.persist(user, [])

      assert Store.existence_signal?(agent)
      refute Store.existence_signal?(user)
    end
  end

  # -------------------------------------------------------------------
  # Helpers (mirrors Ezagent.EntityCapsTest)
  # -------------------------------------------------------------------

  defp issued_cap(receiver, action) do
    unsigned = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: URI.new!("session://identity-caps-store/default/main"),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now()
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(unsigned.instance, :session)
    authority_signed_cap_as!(authority, @issuer, receiver, unsigned)
  end

  defp licensed_caps(receiver, caps), do: [self_license(receiver) | caps]

  defp self_license(receiver) do
    {:ok, type} = Ezagent.URI.type(receiver)
    kind = String.to_existing_atom(type)
    {:ok, authority} = Ezagent.Cap.Authority.open(receiver, kind)

    requested =
      Capability.cap(
        kind,
        Ezagent.ActionSet.Identity,
        :self_license,
        receiver,
        Ezagent.URI.workspace_of(receiver)
      )

    intent = Ezagent.Cap.Grant.freeze(receiver, receiver, receiver, requested)

    {:ok, license} =
      Ezagent.Cap.Authority.with_current(authority, fn ->
        Ezagent.Cap.Authority.issue_self_license_current(intent)
      end)

    license
  end

  defp user_uri(suffix),
    do: URI.new!("entity://identity-caps-store/user/#{suffix}-#{System.unique_integer([:positive])}")

  defp agent_uri(suffix),
    do:
      URI.new!("entity://identity-caps-store/agent/#{suffix}-#{System.unique_integer([:positive])}")

  defp identity_keys(caps) do
    caps
    |> Enum.map(&Capability.identity_key/1)
    |> MapSet.new()
  end

  defp cap_present?(caps, cap),
    do: Capability.identity_key(cap) in identity_keys(caps)

  defp wait_until_ready(uri),
    do: wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
