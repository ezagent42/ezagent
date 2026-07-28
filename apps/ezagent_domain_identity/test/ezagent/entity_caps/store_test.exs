defmodule Ezagent.EntityCaps.StoreTest do
  @moduledoc """
  #189 PR-1 — unit tests for the unified per-entity identity-caps store
  (cutover step 1, ADDITIVE write-shadow): round-trip, dual-write shadow
  parity, legacy-authoritative reads under divergence, mirror-failure
  logging, status transitions, tombstone, and the hardened
  provisioning-receipt API (codex F1–F5).
  """

  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog
  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.{Capability, EntityCaps, SnapshotStore}
  alias Ezagent.EntityCaps.{Store, UserStore}
  alias Ezagent.Identity.ProvisioningReceipt

  @workspace URI.new!("workspace://identity-caps-store")
  @issuer URI.new!("entity://identity-caps-store/user/issuer")
  # An operator that passes `AdminAuthority.admin?/1` via the URI predicate
  # (`workspace://system` home) — no caps needed.
  @system_actor URI.new!("entity://system/user/provisioner")
  @other_system_actor URI.new!("entity://system/user/other-provisioner")

  @test_secret "test-only-provisioning-receipt-secret"

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
      assert row.workspace_uri == "workspace://identity-caps-store"
      assert Store.has_row?(agent)
      assert Store.status(agent) == :active
    end

    test "persist upserts, preserving status and receipt" do
      agent = agent_uri("upsert")
      first = licensed_caps(agent, [issued_cap(agent, :send)])
      second = licensed_caps(agent, [issued_cap(agent, :join)])
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, first)

      assert :ok = Store.provision(agent, first, receipt, actor: @system_actor)
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

    test "fetch_durable_caps falls back only when no row exists (cutover-facing)" do
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

  describe "legacy-authoritative reads under shadow divergence (codex F1)" do
    test "a divergent shadow row never overrides the authoritative caps_json read" do
      user = user_uri("divergent-user")
      legacy_cap = issued_cap(user, :send)
      shadow_cap = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, licensed_caps(user, [legacy_cap]))

      # Populate the shadow with a DIFFERENT set (simulating a lost/failed
      # mirror write divergence).
      assert :ok = Store.persist(user, licensed_caps(user, [shadow_cap]))
      assert cap_present?(Store.load(user), shadow_cap)

      # Authoritative reads still serve users.caps_json — the shadow is
      # never consulted.
      assert cap_present?(EntityCaps.load_persisted(user), legacy_cap)
      refute cap_present?(EntityCaps.load_persisted(user), shadow_cap)
      assert cap_present?(EntityCaps.load(user), legacy_cap)
      refute cap_present?(EntityCaps.load(user), shadow_cap)
    end

    test "a divergent shadow row never overrides the authoritative snapshot read" do
      agent = agent_uri("divergent-agent")
      legacy_cap = issued_cap(agent, :send)
      shadow_cap = issued_cap(agent, :join)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [legacy_cap]))}}},
                 kind_type: :agent
               )

      # The shadow mirrors the snapshot after the write hook…
      assert cap_present?(Store.load(agent), legacy_cap)
      # …force divergence (a granted cap that only exists in the shadow).
      assert :ok = Store.persist(agent, licensed_caps(agent, [shadow_cap]))
      assert cap_present?(Store.load(agent), shadow_cap)

      # Authoritative durable reads still serve the snapshot.
      assert cap_present?(EntityCaps.load_persisted(agent), legacy_cap)
      refute cap_present?(EntityCaps.load_persisted(agent), shadow_cap)

      assert {:ok, %{caps: durable_caps}, _meta} = Ezagent.Kind.read_durable(agent, :identity)
      durable = MapSet.to_list(durable_caps)
      assert cap_present?(durable, legacy_cap)
      refute cap_present?(durable, shadow_cap)
    end

    test "a mirror-write failure is logged at :error and never changes an authz read" do
      agent = agent_uri("mirror-failure")
      cap = issued_cap(agent, :send)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [cap]))}}},
                 kind_type: :agent
               )

      log =
        capture_log(fn ->
          # A caps set that cannot be encoded forces the mirror write to
          # fail inside the shadow hook.
          assert :ok = Store.sync_committed_identity(agent, nil, %{caps: MapSet.new([:bogus])})
        end)

      assert log =~ "shadow write"

      # The authoritative read is untouched.
      assert cap_present?(EntityCaps.load_persisted(agent), cap)
    end
  end

  describe "status transitions + tombstone" do
    test "provision activates with receipt; revoke leaves revoked_unprovisioned" do
      agent = agent_uri("lifecycle")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, caps)

      assert :ok = Store.provision(agent, caps, receipt, actor: @system_actor)
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
               Store.provision(agent, caps, ProvisioningReceipt.issue(agent, @system_actor, :reprovision, caps),
                 actor: @system_actor
               )

      assert {:error, :invalid_provisioning_receipt} =
               Store.provision(agent, caps, ProvisioningReceipt.issue(other, @system_actor, :provision, caps),
                 actor: @system_actor
               )

      tampered =
        agent
        |> ProvisioningReceipt.issue(@system_actor, :provision, caps)
        |> Map.put(:nonce, "forged-nonce")

      assert {:error, :invalid_provisioning_receipt} =
               Store.provision(agent, caps, tampered, actor: @system_actor)

      refute Store.has_row?(agent)
    end

    test "reprovision is the only way out of revoked_unprovisioned" do
      agent = agent_uri("reprovision")
      old_caps = licensed_caps(agent, [issued_cap(agent, :send)])
      new_caps = licensed_caps(agent, [issued_cap(agent, :join)])

      assert :ok =
               Store.provision(agent, old_caps, ProvisioningReceipt.issue(agent, @system_actor, :provision, old_caps),
                 actor: @system_actor
               )

      assert :ok = Store.revoke_provisioning(agent)

      assert {:error, :invalid_provisioning_receipt} =
               Store.reprovision(agent, new_caps, ProvisioningReceipt.issue(agent, @system_actor, :provision, new_caps),
                 actor: @system_actor
               )

      assert :ok =
               Store.reprovision(agent, new_caps, ProvisioningReceipt.issue(agent, @system_actor, :reprovision, new_caps),
                 actor: @system_actor
               )

      assert Store.status(agent) == :active
      assert identity_keys(Store.load(agent)) == identity_keys(new_caps)

      assert {:error, :already_active} =
               Store.reprovision(agent, new_caps, ProvisioningReceipt.issue(agent, @system_actor, :reprovision, new_caps),
                 actor: @system_actor
               )
    end

    test "tombstone is terminal without an authenticated reprovision" do
      agent = agent_uri("tombstone")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])

      assert :ok =
               Store.provision(agent, caps, ProvisioningReceipt.issue(agent, @system_actor, :provision, caps),
                 actor: @system_actor
               )

      assert :ok = Store.tombstone(agent)
      assert Store.status(agent) == :tombstoned
      assert Store.load(agent) == []

      # Monotone: no transition back except authenticated reprovision.
      assert {:error, :tombstoned} = Store.revoke_provisioning(agent)

      assert {:error, :tombstoned} =
               Store.provision(agent, caps, ProvisioningReceipt.issue(agent, @system_actor, :provision, caps),
                 actor: @system_actor
               )

      assert :ok =
               Store.reprovision(agent, caps, ProvisioningReceipt.issue(agent, @system_actor, :reprovision, caps),
                 actor: @system_actor
               )

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

  describe "ProvisioningReceipt hardening (codex F3/F4)" do
    test "issue/verify round-trip and to_json/from_json round-trip" do
      agent = agent_uri("receipt")
      caps = licensed_caps(agent, [])
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, caps)

      assert ProvisioningReceipt.verify(receipt)
      assert ProvisioningReceipt.fresh?(receipt)
      assert ProvisioningReceipt.valid_for?(receipt, agent, :provision, caps)
      refute ProvisioningReceipt.valid_for?(receipt, agent, :reprovision, caps)
      refute ProvisioningReceipt.valid_for?(receipt, agent_uri("receipt-other"), :provision, caps)

      assert {:ok, decoded} =
               receipt |> ProvisioningReceipt.to_json() |> ProvisioningReceipt.from_json()

      assert decoded == receipt
      assert ProvisioningReceipt.verify(decoded)

      assert {:error, :invalid_receipt} = ProvisioningReceipt.from_json(nil)
      assert {:error, :invalid_receipt} = ProvisioningReceipt.from_json("not json")
      assert {:error, :invalid_receipt} = ProvisioningReceipt.from_json(~s({"transition": "bogus"}))
    end

    test "receipts are single-use — a replay is rejected" do
      agent = agent_uri("replay")
      caps = licensed_caps(agent, [])
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, caps)

      assert :ok = Store.provision(agent, caps, receipt, actor: @system_actor)

      assert {:error, :receipt_already_used} =
               Store.provision(agent, caps, receipt, actor: @system_actor)
    end

    test "a receipt cannot activate a different cap set than it was issued for (digest binding)" do
      agent = agent_uri("digest")
      caps_a = licensed_caps(agent, [issued_cap(agent, :send)])
      caps_b = licensed_caps(agent, [issued_cap(agent, :join)])
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, caps_a)

      refute ProvisioningReceipt.valid_for?(receipt, agent, :provision, caps_b)

      assert {:error, :invalid_provisioning_receipt} =
               Store.provision(agent, caps_b, receipt, actor: @system_actor)

      refute Store.has_row?(agent)
    end

    test "stale receipts are rejected (TTL)" do
      agent = agent_uri("ttl")
      caps = licensed_caps(agent, [])

      stale =
        ProvisioningReceipt.issue(agent, @system_actor, :provision, caps,
          issued_at: DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:microsecond)
        )

      refute ProvisioningReceipt.fresh?(stale)
      refute ProvisioningReceipt.valid_for?(stale, agent, :provision, caps)

      assert {:error, :invalid_provisioning_receipt} =
               Store.provision(agent, caps, stale, actor: @system_actor)
    end

    test "the actor must match the receipt AND be an authorized admin" do
      agent = agent_uri("actor")
      caps = licensed_caps(agent, [])

      # A non-admin actor cannot provision even with a receipt issued to it.
      stranger = user_uri("stranger")
      stranger_receipt = ProvisioningReceipt.issue(agent, stranger, :provision, caps)

      assert {:error, :unauthorized_actor} =
               Store.provision(agent, caps, stranger_receipt, actor: stranger)

      # A different admin cannot spend another actor's receipt.
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, caps)

      assert {:error, :unauthorized_actor} =
               Store.provision(agent, caps, receipt, actor: @other_system_actor)

      assert :ok = Store.provision(agent, caps, receipt, actor: @system_actor)
    end

    test "blank or weak secrets are rejected at receipt use (never truthy-by-default)" do
      try do
        for bad_secret <- ["", "too-short"] do
          Application.put_env(:ezagent_domain_identity, :provisioning_receipt_secret, bad_secret)

          assert_raise RuntimeError, fn ->
            ProvisioningReceipt.issue(agent_uri("secret"), @system_actor, :provision, [])
          end
        end
      after
        Application.put_env(:ezagent_domain_identity, :provisioning_receipt_secret, @test_secret)
      end
    end
  end

  describe "dual-write shadow (users)" do
    test "UserStore writes mirror into the unified store in the same transaction" do
      user = user_uri("parity-user")
      first = issued_cap(user, :send)
      second = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, licensed_caps(user, [first]))
      # Users.create writes caps_json directly (not via UserStore), so the
      # shadow row appears at the first UserStore write.
      refute Store.has_row?(user)

      assert :ok = UserStore.persist(user, licensed_caps(user, [first, second]))
      assert identity_keys(Store.load(user)) == identity_keys(UserStore.load(user))

      assert :ok =
               UserStore.update(user, fn caps ->
                 {:ok, Enum.reject(caps, &(&1.action == :send))}
               end)

      assert identity_keys(Store.load(user)) == identity_keys(UserStore.load(user))
      refute cap_present?(Store.load(user), first)
    end
  end

  describe "dual-write shadow (snapshot plane)" do
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
      # The authoritative durable read serves the same cap from the snapshot.
      assert cap_present?(EntityCaps.load_persisted(agent), cap)
    end

    test "SnapshotStore.delete clears the shadow row too" do
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

      # The initial persist (save_now) already mirrors the minted set.
      assert Store.has_row?(agent)
      assert cap_present?(Store.load(agent), first)

      assert :ok = EntityCaps.grant(agent, second)
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

      # The same slice on the direct-write path (nil kind_module) mirrors.
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
