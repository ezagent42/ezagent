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
  import Ecto.Query
  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.{Capability, EntityCaps, SnapshotStore}
  alias Ezagent.Cap.{Delivery, RevocationLedger}
  alias Ezagent.EntityCaps.{Store, UserStore}
  alias Ezagent.Identity.ProvisioningReceipt
  alias EzagentCore.Repo

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
    Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)
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

    on_exit(fn ->
      Application.delete_env(:ezagent_core, :cap_revocation_ledger_force_read_error)
      Ezagent.EntityCapsReadyBarrier.clear()
    end)

    :ok
  end

  describe "round-trip" do
    test "durable revoke resolves the stored grant_id, cancels pending delivery, and reindexes" do
      agent = agent_uri("durable-revoke-stored")
      stored = v2_issued_cap(agent, :send)
      caps = licensed_caps(agent, [stored])

      assert :ok = Store.persist(agent, caps)
      assert :ok = Ezagent.Identity.absorb_cap(agent, stored)

      pending =
        Repo.one!(
          from(delivery in Delivery,
            where: delivery.grant_id == ^stored.grant_id and delivery.status == :pending
          )
        )

      caller_supplied = %{stored | grant_id: Ecto.UUID.generate()}
      random_id = caller_supplied.grant_id

      assert {:ok, resolved} = Store.revoke_cap(agent, caller_supplied)
      assert resolved.grant_id == stored.grant_id

      assert {:ok, revoked} =
               RevocationLedger.revoked_grant_ids(@workspace, [stored.grant_id, random_id])

      assert revoked == MapSet.new([stored.grant_id])
      refute cap_present?(Store.load(agent), stored)
      assert Repo.get(Delivery, pending.id) == nil

      refute Repo.exists?(
               from(row in Ezagent.EntityCaps.GranteeIndex,
                 where:
                   row.grantee_uri == ^Ezagent.URI.stable_key(agent) and
                     row.target_uri == ^Ezagent.URI.stable_key(stored.instance)
               )
             )
    end

    test "absent-from-Store revoke requires an exact current artifact for this holder" do
      agent = agent_uri("durable-revoke-absent")
      assert :ok = Store.persist(agent, licensed_caps(agent, []))

      exact = v2_issued_cap(agent, :send)
      assert {:ok, ^exact} = Store.revoke_cap(agent, exact)

      assert {:ok, revoked} = RevocationLedger.revoked_grant_ids(@workspace, [exact.grant_id])
      assert revoked == MapSet.new([exact.grant_id])

      unsigned = %{v2_issued_cap(agent, :join) | signature: nil}
      assert {:error, :invalid_exact_revocation_artifact} = Store.revoke_cap(agent, unsigned)

      other_holder = agent_uri("durable-revoke-wrong-holder")
      wrong_holder = v2_issued_cap(other_holder, :history)

      assert {:error, :invalid_exact_revocation_artifact} =
               Store.revoke_cap(agent, wrong_holder)

      stale_target =
        URI.new!(
          "session://identity-caps-store/default/stale-#{System.unique_integer([:positive])}"
        )

      stale = v2_issued_cap(agent, :manage, stale_target)
      assert {:ok, _next_generation} = Ezagent.Cap.Authority.regenesis(stale_target, :session)

      assert {:error, :invalid_exact_revocation_artifact} = Store.revoke_cap(agent, stale)
    end

    test "all cap-set writers reject an absorbing revoked v2 artifact" do
      persist_agent = agent_uri("revoked-persist")
      persist_cap = v2_issued_cap(persist_agent, :send)
      persist_grant_id = persist_cap.grant_id
      :ok = revoke_cap(persist_agent, persist_cap)

      assert {:error, {:revoked_capability_grants, [^persist_grant_id]}} =
               Store.persist(persist_agent, licensed_caps(persist_agent, [persist_cap]))

      refute Store.has_row?(persist_agent)

      update_agent = agent_uri("revoked-update")
      baseline = licensed_caps(update_agent, [issued_cap(update_agent, :send)])
      update_cap = v2_issued_cap(update_agent, :join)
      update_grant_id = update_cap.grant_id
      assert :ok = Store.persist(update_agent, baseline)
      :ok = revoke_cap(update_agent, update_cap)

      assert {:error, {:revoked_capability_grants, [^update_grant_id]}} =
               Store.update(update_agent, fn current -> {:ok, current ++ [update_cap]} end)

      assert identity_keys(Store.load(update_agent)) == identity_keys(baseline)

      backfill_agent = agent_uri("revoked-backfill")
      backfill_cap = v2_issued_cap(backfill_agent, :send)
      backfill_grant_id = backfill_cap.grant_id
      :ok = revoke_cap(backfill_agent, backfill_cap)

      assert {:error, {:revoked_capability_grants, [^backfill_grant_id]}} =
               Store.backfill(
                 backfill_agent,
                 licensed_caps(backfill_agent, [backfill_cap])
               )

      refute Store.has_row?(backfill_agent)

      provision_agent = agent_uri("revoked-provision")
      provision_cap = v2_issued_cap(provision_agent, :send)
      provision_grant_id = provision_cap.grant_id
      provision_caps = licensed_caps(provision_agent, [provision_cap])

      receipt =
        ProvisioningReceipt.issue(provision_agent, @system_actor, :provision, provision_caps)

      :ok = revoke_cap(provision_agent, provision_cap)

      assert {:error, {:revoked_capability_grants, [^provision_grant_id]}} =
               Store.provision(provision_agent, provision_caps, receipt, actor: @system_actor)

      refute Store.has_row?(provision_agent)
    end

    test "the shared write gate rolls back when the revocation ledger is unreadable" do
      agent = agent_uri("ledger-unreadable")
      caps = licensed_caps(agent, [v2_issued_cap(agent, :send)])

      Application.put_env(:ezagent_core, :cap_revocation_ledger_force_read_error, true)

      assert {:error, :cap_revocation_ledger_unreadable} = Store.persist(agent, caps)
      refute Store.has_row?(agent)
    end

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

    test "update/2 routes through the resurrection guard (codex impl-review finding 1(a))" do
      # FAIL-BEFORE / PASS-AFTER: pre-fix, `update/2` inserted an absent row on
      # the schema's `"active"` default and wrote caps with NO self-license
      # check — an ordinary issued cap would leave the row `active` (the bypass
      # codex finding 1 named, demonstrated by the old store_test.exs:109). The
      # guard now decides the status structurally from the transformed caps.
      unlicensed = agent_uri("update-unlicensed")
      cap = issued_cap(unlicensed, :send)

      refute Store.has_row?(unlicensed)
      assert :ok = Store.update(unlicensed, fn current -> {:ok, current ++ [cap]} end)
      # No current-valid self-license ⇒ revoked_unprovisioned, NEVER active.
      assert Store.status(unlicensed) == :revoked_unprovisioned
      assert Store.load(unlicensed) == []
      # The row EXISTS (never left absent) — a later stale write can't recreate
      # it active.
      assert Store.has_row?(unlicensed)

      # A fresh-row update whose result carries a CURRENT-valid self-license
      # legitimately activates (the guard permits the valid case).
      licensed = agent_uri("update-licensed")
      licensed_set = licensed_caps(licensed, [issued_cap(licensed, :send)])
      assert :ok = Store.update(licensed, fn _current -> {:ok, licensed_set} end)
      assert Store.status(licensed) == :active
      assert identity_keys(Store.load(licensed)) == identity_keys(licensed_set)

      # The fun's own error still rolls the transaction back, leaving prior
      # state intact.
      assert {:error, :boom} = Store.update(licensed, fn _current -> {:error, :boom} end)
      assert Store.status(licensed) == :active
      assert cap_present?(Store.load(licensed), Enum.at(licensed_set, 1))
    end

    test "fetch_durable_caps is :absent only when no row exists (cutover-facing)" do
      agent = agent_uri("dual-read-shape")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])

      # FIX 2: a SUCCESSFUL absent read is `:absent` (fallback-eligible), NOT a
      # collapsed `nil`/error. A present row is `{:ok, _}`; a read failure is
      # `{:error, _}` (covered by the dedicated read-error regression below).
      assert Store.fetch_durable_caps(agent) == :absent

      assert :ok = Store.persist(agent, caps)
      assert {:ok, store_caps} = Store.fetch_durable_caps(agent)
      assert identity_keys(store_caps) == identity_keys(caps)

      assert :ok = Store.revoke_provisioning(agent)
      assert {:ok, []} = Store.fetch_durable_caps(agent)
    end
  end

  describe "store-authoritative durable reads (#189 PR-3 read-cutover)" do
    # PR-1/PR-2 kept legacy (`users.caps_json` / snapshot `:identity`)
    # authoritative and the store a write-shadow; PR-3 flips
    # `EntityCaps.load_persisted/1` (the cold/self durable read behind the
    # principal-axis gate) to the STORE as authoritative, with a legacy fallback
    # ONLY for an ABSENT row. The security property that PR-1's "legacy wins"
    # tests protected — a divergent/invalid shadow must not grant authority — is
    # now preserved by (a) the write-boundary guard (an `active` row carries a
    # current-valid self-license) and (b) `EntityCaps.verified/2` gen-gating
    # every read, exercised by the anti-resurrection regression.

    test "a present active store row is authoritative for a user (store-preferred over legacy caps_json)" do
      user = user_uri("cutover-user")
      legacy_cap = issued_cap(user, :send)
      store_cap = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, licensed_caps(user, [legacy_cap]))

      # The guarded active store row (it carries a current-valid self-license) is
      # now the AUTHORITATIVE durable holder source; legacy is consulted ONLY on
      # an absent row.
      assert :ok = Store.persist(user, licensed_caps(user, [store_cap]))
      assert Store.status(user) == :active

      assert cap_present?(EntityCaps.load_persisted(user), store_cap)
      refute cap_present?(EntityCaps.load_persisted(user), legacy_cap)
    end

    test "a present active store row is authoritative for a snapshot-backed agent (store-preferred over the snapshot)" do
      agent = agent_uri("cutover-agent")
      legacy_cap = issued_cap(agent, :send)
      store_cap = issued_cap(agent, :join)

      assert {:ok, _snapshot} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [legacy_cap]))}}},
                 kind_type: :agent
               )

      assert :ok = Store.persist(agent, licensed_caps(agent, [store_cap]))
      assert Store.status(agent) == :active

      assert cap_present?(EntityCaps.load_persisted(agent), store_cap)
      refute cap_present?(EntityCaps.load_persisted(agent), legacy_cap)
    end

    test "a present NON-active store row is authoritative-EMPTY — it denies without falling back to legacy" do
      user = user_uri("cutover-revoked-user")
      legacy_cap = issued_cap(user, :send)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, licensed_caps(user, [legacy_cap]))

      assert :ok = Store.persist(user, licensed_caps(user, [legacy_cap]))
      assert :ok = Store.revoke_provisioning(user)
      assert Store.status(user) == :revoked_unprovisioned

      # A present non-active (revoked) row is authoritative about the holder
      # being EMPTY — it does NOT fall back to the legacy caps_json, which still
      # carries the cap. This is the inert-until-reprovision guarantee.
      assert EntityCaps.load_persisted(user) == []
    end

    test "POST-epoch a mirror-write failure is authoritative ({:error}), logged, and never changes an authz read" do
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
          # A caps set that cannot be encoded forces the identity write to fail.
          # POST-epoch the store is AUTHORITATIVE (FIX 1), so the failure is
          # PROPAGATED as `{:error, _}` (never swallowed to `:ok`).
          assert {:error, _} =
                   Store.sync_committed_identity(agent, nil, %{caps: MapSet.new([:bogus])})
        end)

      assert log =~ "identity write"

      # The failed write changed nothing — the authoritative read is untouched.
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
               Store.provision(
                 agent,
                 caps,
                 ProvisioningReceipt.issue(agent, @system_actor, :reprovision, caps),
                 actor: @system_actor
               )

      assert {:error, :invalid_provisioning_receipt} =
               Store.provision(
                 agent,
                 caps,
                 ProvisioningReceipt.issue(other, @system_actor, :provision, caps),
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
               Store.provision(
                 agent,
                 old_caps,
                 ProvisioningReceipt.issue(agent, @system_actor, :provision, old_caps),
                 actor: @system_actor
               )

      assert :ok = Store.revoke_provisioning(agent)

      assert {:error, :invalid_provisioning_receipt} =
               Store.reprovision(
                 agent,
                 new_caps,
                 ProvisioningReceipt.issue(agent, @system_actor, :provision, new_caps),
                 actor: @system_actor
               )

      assert :ok =
               Store.reprovision(
                 agent,
                 new_caps,
                 ProvisioningReceipt.issue(agent, @system_actor, :reprovision, new_caps),
                 actor: @system_actor
               )

      assert Store.status(agent) == :active
      assert identity_keys(Store.load(agent)) == identity_keys(new_caps)

      assert {:error, :already_active} =
               Store.reprovision(
                 agent,
                 new_caps,
                 ProvisioningReceipt.issue(agent, @system_actor, :reprovision, new_caps),
                 actor: @system_actor
               )
    end

    test "tombstone is terminal without an authenticated reprovision" do
      agent = agent_uri("tombstone")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])

      assert :ok =
               Store.provision(
                 agent,
                 caps,
                 ProvisioningReceipt.issue(agent, @system_actor, :provision, caps),
                 actor: @system_actor
               )

      assert :ok = Store.tombstone(agent)
      assert Store.status(agent) == :tombstoned
      assert Store.load(agent) == []

      # Monotone: no transition back except authenticated reprovision.
      assert {:error, :tombstoned} = Store.revoke_provisioning(agent)

      assert {:error, :tombstoned} =
               Store.provision(
                 agent,
                 caps,
                 ProvisioningReceipt.issue(agent, @system_actor, :provision, caps),
                 actor: @system_actor
               )

      assert :ok =
               Store.reprovision(
                 agent,
                 caps,
                 ProvisioningReceipt.issue(agent, @system_actor, :reprovision, caps),
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

      assert {:error, :invalid_receipt} =
               ProvisioningReceipt.from_json(~s({"transition": "bogus"}))
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
          issued_at:
            DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:microsecond)
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
    test "UserStore writes mirror into the unified store (write-shadow, outside the caps_json transaction)" do
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

    test "PRE-EPOCH a shadow-write failure never rolls back the authoritative caps_json write (logged, not silent)" do
      # This is the PR-1 F2 (PRE-cutover) contract: caps_json is authoritative and
      # a shadow-store failure must not fail it. Post-epoch the contract INVERTS
      # (store-authoritative — covered by the FIX 1 regressions below), so force
      # PRE-epoch here (the suite otherwise forces the epoch active).
      Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, false)

      on_exit(fn ->
        Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, true)
      end)

      user = user_uri("shadow-failure")
      first = issued_cap(user, :send)
      second = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, licensed_caps(user, [first]))

      # Force the SHADOW `Store.persist/2` to fail for this URI (the
      # MIX_ENV=test-only `:p1_forced_shadow_failure_uris` seam, the
      # `Kind.Snapshot` p2_5c precedent) while the legacy `caps_json`
      # write succeeds normally.
      Application.put_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris, [
        URI.to_string(user)
      ])

      try do
        log =
          capture_log(fn ->
            assert :ok = UserStore.persist(user, licensed_caps(user, [second]))
          end)

        # The failure is logged at :error — never silently dropped.
        assert log =~ "identity-caps shadow write FAILED"
        assert log =~ "caps_json committed"

        # STRUCTURAL invariant (codex round-4) — this is what actually PROVES
        # F2. The shadow write ran OUTSIDE the authoritative `caps_json`
        # transaction (`Repo.in_transaction?() == false` at mirror time). If the
        # mirror were moved back inside `Repo.transaction/1` (the pre-F2 layout),
        # this flips to `true` and the test goes red. Without it the outcome
        # assertions below pass even in the pre-F2 layout, because a returned
        # `{:error}` (vs a DB-statement error) never poisons the enclosing txn —
        # so they alone do not distinguish the two layouts.
        assert Process.get(:p1_forced_shadow_failure_in_transaction?) == false
      after
        Application.delete_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris)
        Process.delete(:p1_forced_shadow_failure_in_transaction?)
      end

      # The AUTHORITATIVE users.caps_json write committed despite the
      # shadow failure…
      assert cap_present?(UserStore.load(user), second)
      refute cap_present?(UserStore.load(user), first)
      # …and so did the authoritative EntityCaps read.
      assert cap_present?(EntityCaps.load_persisted(user), second)

      # The shadow diverged (its write failed) — observable, not silent.
      refute Store.has_row?(user)
    end
  end

  describe "#189 PR-3 FIX 1 (post-epoch: the identity store write is AUTHORITATIVE)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris)
      end)
    end

    test "a forced store failure FAILS a user GRANT from a present row — no silent success" do
      user = user_uri("fix1-user-grant")
      base = licensed_caps(user, [issued_cap(user, :send)])
      extra = issued_cap(user, :join)

      assert {:ok, _user} = Ezagent.Users.create(user, nil, base)
      assert :ok = UserStore.persist(user, base)
      assert Store.status(user) == :active
      before = identity_keys(Store.load(user))

      Application.put_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris, [
        URI.to_string(user)
      ])

      # The grant cannot reach the AUTHORITATIVE store, so the mutation FAILS —
      # the caller must not receive `:ok`.
      assert {:error, _} = UserStore.persist(user, base ++ [extra])

      # The authoritative store is UNCHANGED (the grant did not take).
      assert identity_keys(Store.load(user)) == before
      refute cap_present?(Store.load(user), extra)
    end

    test "a forced store failure FAILS a user REMOVAL from a present row — cap not silently gone" do
      user = user_uri("fix1-user-remove")
      keep = issued_cap(user, :send)
      drop = issued_cap(user, :join)
      base = licensed_caps(user, [keep, drop])

      assert {:ok, _user} = Ezagent.Users.create(user, nil, base)
      assert :ok = UserStore.persist(user, base)
      assert cap_present?(Store.load(user), drop)

      Application.put_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris, [
        URI.to_string(user)
      ])

      # A MISSED removal must not report success — and the cap must STILL be
      # present in the authoritative store (no silent divergence where the caller
      # thinks it removed a cap that the authoritative plane still holds).
      assert {:error, _} = UserStore.persist(user, licensed_caps(user, [keep]))
      assert cap_present?(Store.load(user), drop)
    end

    test "a forced store failure FAILS the snapshot commit (Store-first gates the upsert)" do
      agent = agent_uri("fix1-snapshot")
      base = licensed_caps(agent, [issued_cap(agent, :send)])

      assert {:ok, _} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(base)}}},
                 kind_type: :agent
               )

      assert Store.status(agent) == :active

      Application.put_env(:ezagent_domain_identity, :p1_forced_shadow_failure_uris, [
        URI.to_string(agent)
      ])

      # Store-first: the authoritative identity write is attempted BEFORE the
      # snapshot upsert, so a store failure aborts the whole commit.
      assert {:error, {:identity_store_write_failed, _}} =
               SnapshotStore.write(
                 agent,
                 %{
                   identity: %{
                     state: %{caps: MapSet.new(base ++ [issued_cap(agent, :publish)])}
                   }
                 },
                 kind_type: :agent
               )
    end
  end

  describe "#189 PR-3 FINAL ITEM 1 (post-epoch second-write hole: store commits, snapshot FAILS)" do
    # The Store-first order closes the REVOKE hole (a store failure aborts before
    # the snapshot). But the SECOND write — the snapshot projection — can still
    # fail AFTER the authoritative store already committed. Pre-fix the writer
    # returned `{:error}` there, so the caller reported `persistence_failed` and
    # kept stale live state WHILE the authoritative store (which self-authz reads)
    # already held the mutation — a divergence between the reported outcome and the
    # authoritative plane. The fix: an authoritative store commit means the
    # mutation IS committed, so a snapshot-projection failure is reported as
    # SUCCESS (the projection converges on the next write / cold-load reconcile).
    setup do
      on_exit(fn -> Application.delete_env(:ezagent_actor, :p3_forced_snapshot_failure_uris) end)
    end

    test "GRANT: store commits + snapshot projection fails => caller sees :ok AND the store reflects the grant" do
      agent = agent_uri("item1-grant")
      base = licensed_caps(agent, [issued_cap(agent, :send)])

      assert {:ok, _} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(base)}}},
                 kind_type: :agent
               )

      assert Store.status(agent) == :active
      added = issued_cap(agent, :publish)

      # Force ONLY the snapshot upsert to fail; the Store-first authoritative
      # write still commits.
      Application.put_env(:ezagent_actor, :p3_forced_snapshot_failure_uris, [URI.to_string(agent)])

      # No divergence: the authoritative store committed the grant, so the writer
      # MUST report success — never `{:error}` while the store holds the mutation.
      assert {:ok, _} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(base ++ [added])}}},
                 kind_type: :agent
               )

      # The reported success matches the authoritative plane the self-authz read
      # (post-epoch, store-authoritative) consults.
      assert cap_present?(Store.load(agent), added)
      assert cap_present?(EntityCaps.load_persisted(agent), added)
    end

    test "REMOVAL: store commits + snapshot projection fails => caller sees :ok AND the store reflects the removal" do
      agent = agent_uri("item1-remove")
      keep = issued_cap(agent, :send)
      drop = issued_cap(agent, :publish)
      base = licensed_caps(agent, [keep, drop])

      assert {:ok, _} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(base)}}},
                 kind_type: :agent
               )

      assert cap_present?(Store.load(agent), drop)

      Application.put_env(:ezagent_actor, :p3_forced_snapshot_failure_uris, [URI.to_string(agent)])

      # The revoke reaches the authoritative store FIRST; a snapshot failure must
      # not make the caller believe the removal failed while the store dropped it.
      assert {:ok, _} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new(licensed_caps(agent, [keep]))}}},
                 kind_type: :agent
               )

      refute cap_present?(Store.load(agent), drop)
      refute cap_present?(EntityCaps.load_persisted(agent), drop)
    end
  end

  describe "#189 PR-3 FINAL ITEM 1 (cold-restart reconcile: a stale snapshot must NOT roll back the authoritative Store)" do
    # The second-write fix reports a post-epoch cap mutation as SUCCESS the instant
    # the authoritative Store row lands, even when the SNAPSHOT projection fails —
    # leaving a STALE snapshot on disk (the exact ITEM-1 seam,
    # `SnapshotStore.write` under `:p3_forced_snapshot_failure`, Store ahead of the
    # snapshot). This is the dangerous sequel: a COLD RELOAD before another
    # successful write loads that stale snapshot and — through the actor's initial
    # `save_now` — mirrors it back into `Store.persist`. WITHOUT the cold-load
    # reconcile, that mirror-back OVERWRITES the committed mutation (rolling back a
    # grant / RESURRECTING a revoked cap) and leaves the live slice cross-Kind authz
    # reads stale. The reconcile replaces the rehydrated slice's caps with the
    # store's authoritative set BEFORE the initial persist, so the Store, the live
    # slice, the persisted read, AND authorization all retain the committed result.
    #
    # We construct the divergence deterministically (graceful terminate → the
    # ITEM-1 `SnapshotStore.write` seam → cold re-spawn) rather than by a
    # brutal-kill mid-mutation: the init reconcile is the SAME code path either way
    # (Identity's `deactivate/2` is `:ok`-only, so a graceful stop and a brutal kill
    # leave the identical on-disk snapshot), and a mid-query brutal kill tears the
    # DataCase shared-sandbox connection. The existing ITEM-1 tests exercise the
    # forced snapshot failure but NEVER cold-reload the Kind, so they cannot catch
    # this.
    setup do
      on_exit(fn -> Application.delete_env(:ezagent_actor, :p3_forced_snapshot_failure_uris) end)
    end

    test "GRANT survives a cold reload — the store commit is not rolled back by the stale snapshot" do
      agent = agent_uri("item1-reload-grant")
      keep = issued_cap(agent, :send)
      added = issued_cap(agent, :publish)

      # 1. Live-create the principal, then bring it down GRACEFULLY: the marker +
      #    snapshot {license, keep} + the store row are all durably written.
      {:ok, _pid} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: [keep]})
      wait_until_ready(agent)
      assert Store.status(agent) == :active
      assert cap_present?(Store.load(agent), keep)
      refute cap_present?(Store.load(agent), added)
      :ok = Ezagent.Kind.terminate(agent)
      wait_until(fn -> Ezagent.KindRegistry.lookup(agent) == :error end)

      # 2. Reproduce the ITEM-1 second-write hole while the Kind is DOWN: the
      #    authoritative store commits `added` (Store-first), the snapshot upsert is
      #    forced to fail. The store is now AHEAD of a STALE on-disk snapshot.
      Application.put_env(:ezagent_actor, :p3_forced_snapshot_failure_uris, [URI.to_string(agent)])

      assert {:ok, _} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new([keep, added, self_license(agent)])}}},
                 kind_type: :agent
               )

      assert cap_present?(Store.load(agent), added)
      Application.delete_env(:ezagent_actor, :p3_forced_snapshot_failure_uris)

      # 3. Cold reload from the STALE snapshot (no live mutation in between).
      {:ok, _pid2} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent})
      wait_until_ready(agent)

      # The reload was `:existed` (the marker survived) — NOT a re-created principal
      # (which would skip the reconcile and make this vacuous).
      assert Ezagent.Ecto.KindSnapshot.ever_created?(URI.to_string(agent))

      # WITHOUT the reconcile the stale snapshot mirrors back and DROPS `added`. All
      # four planes must retain the committed grant.
      # 1. Store (authoritative durable holder).
      assert cap_present?(Store.load(agent), added)
      # 2. Live slice (what cross-Kind authz reads live).
      {:ok, %{state: live}} = Ezagent.Kind.SliceAccess.get_raw_slice(agent, :identity)
      assert cap_present?(MapSet.to_list(live.caps), added)
      # 3. Persisted read (post-epoch store-authoritative).
      assert cap_present?(EntityCaps.load_persisted(agent), added)
      # 4. Authorization (live-first, verified/2).
      assert cap_present?(EntityCaps.load(agent), added)
      # Non-vacuous: the base cap (and the self-license) are still present.
      assert cap_present?(Store.load(agent), keep)

      :ok = Ezagent.Kind.terminate(agent)
    end

    test "REVOKE survives a cold reload — the stale snapshot does not resurrect the revoked cap" do
      agent = agent_uri("item1-reload-revoke")
      keep = issued_cap(agent, :send)
      drop = issued_cap(agent, :publish)

      # 1. Live-create with {license, keep, drop}, then graceful stop: marker +
      #    snapshot {license, keep, drop} + store row are durable.
      {:ok, _pid} =
        Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: [keep, drop]})

      wait_until_ready(agent)
      assert Store.status(agent) == :active
      assert cap_present?(Store.load(agent), drop)
      :ok = Ezagent.Kind.terminate(agent)
      wait_until(fn -> Ezagent.KindRegistry.lookup(agent) == :error end)

      # 2. Reproduce the ITEM-1 second-write hole for a REVOKE while DOWN: the store
      #    DROPS `drop` (Store-first authoritative), the snapshot upsert is forced to
      #    fail → the on-disk snapshot STALE-ly still holds `drop`.
      Application.put_env(:ezagent_actor, :p3_forced_snapshot_failure_uris, [URI.to_string(agent)])

      assert {:ok, _} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new([keep, self_license(agent)])}}},
                 kind_type: :agent
               )

      refute cap_present?(Store.load(agent), drop)
      Application.delete_env(:ezagent_actor, :p3_forced_snapshot_failure_uris)

      # 3. Cold reload from the STALE snapshot (which still holds `drop`).
      {:ok, _pid2} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent})
      wait_until_ready(agent)

      assert Ezagent.Ecto.KindSnapshot.ever_created?(URI.to_string(agent))

      # WITHOUT the reconcile the stale snapshot mirrors back and RESURRECTS `drop`.
      # All four planes must retain the committed removal.
      refute cap_present?(Store.load(agent), drop)
      {:ok, %{state: live}} = Ezagent.Kind.SliceAccess.get_raw_slice(agent, :identity)
      refute cap_present?(MapSet.to_list(live.caps), drop)
      refute cap_present?(EntityCaps.load_persisted(agent), drop)
      refute cap_present?(EntityCaps.load(agent), drop)
      # Non-vacuous: the kept cap survived the reload.
      assert cap_present?(Store.load(agent), keep)

      :ok = Ezagent.Kind.terminate(agent)
    end

    test "a Store READ ERROR at cold reload REFUSES the boot — never proceeds on the stale slice" do
      # codex final review: the read path can fail (e.g. an undecodable row)
      # while the mirror-back `persist/2` still SUCCEEDS (`lock_row` reads
      # directly, not through the seam-affected `fetch_result/1`) — so a
      # `:keep`-on-read-error reconcile would deterministically let the stale
      # snapshot overwrite the authoritative Store. The only fail-closed answer
      # is to REFUSE the boot until the store is readable again.
      agent = agent_uri("item1-reload-read-error")
      keep = issued_cap(agent, :send)
      added = issued_cap(agent, :publish)

      # 1. Live-create, then graceful stop: marker + snapshot {license, keep} +
      #    store row are all durable.
      {:ok, _pid} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: [keep]})
      wait_until_ready(agent)
      assert Store.status(agent) == :active
      :ok = Ezagent.Kind.terminate(agent)
      wait_until(fn -> Ezagent.KindRegistry.lookup(agent) == :error end)

      # 2. The ITEM-1 divergence: the store commits `added`, the snapshot upsert
      #    is forced to fail → the store is AHEAD of the stale on-disk snapshot.
      Application.put_env(:ezagent_actor, :p3_forced_snapshot_failure_uris, [URI.to_string(agent)])

      assert {:ok, _} =
               SnapshotStore.write(
                 agent,
                 %{identity: %{state: %{caps: MapSet.new([keep, added, self_license(agent)])}}},
                 kind_type: :agent
               )

      assert cap_present?(Store.load(agent), added)
      Application.delete_env(:ezagent_actor, :p3_forced_snapshot_failure_uris)

      # 3. Cold reload under a FORCED STORE READ ERROR (the FIX-2 seam): the
      #    reconcile cannot read the authoritative set — the boot must REFUSE.
      read_error_key = agent |> Ezagent.URI.instance() |> URI.to_string()
      Application.put_env(:ezagent_domain_identity, :p2_forced_read_error_uris, [read_error_key])

      on_exit(fn ->
        Application.delete_env(:ezagent_domain_identity, :p2_forced_read_error_uris)
      end)

      assert {:error, _reason} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent})

      # The authoritative Store was NOT overwritten by the stale snapshot.
      Application.delete_env(:ezagent_domain_identity, :p2_forced_read_error_uris)
      assert cap_present?(Store.load(agent), added)
      assert cap_present?(Store.load(agent), keep)

      # 4. Recovery: with the store readable again the SAME cold reload succeeds
      #    and reconciles — the committed grant survives on every plane.
      {:ok, _pid2} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent})
      wait_until_ready(agent)
      assert cap_present?(EntityCaps.load(agent), added)

      :ok = Ezagent.Kind.terminate(agent)
    end
  end

  describe "#189 PR-3 FINAL ITEM 2 (an UNREADABLE epoch REJECTS non-user durable mutations)" do
    # The USER path already rejects `:unknown` (`UserStore.update/2`). The non-user
    # durable path (`sync_committed_identity/3`, the snapshot dual-write chokepoint)
    # must be symmetric: on an unreadable epoch a durable identity mutation is
    # REFUSED — the Store, the snapshot, AND the live slice all stay unchanged —
    # rather than advancing state (and the authoritative Store row) under an epoch
    # we cannot read.
    setup do
      on_exit(fn ->
        Application.delete_env(:ezagent_domain_identity, :identity_cutover_force_read_error)
        # Restore the suite-wide active override the rest of the suite relies on.
        Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, true)
      end)

      :ok
    end

    test "a live GRANT under an unreadable epoch is refused; Store, snapshot, and live slice are unchanged" do
      agent = agent_uri("item2-grant-unknown")
      base = issued_cap(agent, :send)
      added = issued_cap(agent, :publish)

      {:ok, _pid} = Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: [base]})
      wait_until_ready(agent)
      assert Store.status(agent) == :active
      before_store = identity_keys(Store.load(agent))
      {:ok, %{state: before_live}} = Ezagent.Kind.SliceAccess.get_raw_slice(agent, :identity)

      # A FRESH post-cutover node whose epoch read ERRORS resolves to `:unknown`.
      Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)
      Application.put_env(:ezagent_domain_identity, :identity_cutover_force_read_error, true)
      assert Ezagent.Identity.Cutover.status() == :unknown

      # The mutation is REFUSED (the durable identity write fails closed) — never
      # reported as success.
      assert {:error, _} = EntityCaps.grant(agent, added)

      # 1. Store unchanged — no row write under `:unknown` (epoch resolved BEFORE
      #    `persist/2`).
      assert identity_keys(Store.load(agent)) == before_store
      refute cap_present?(Store.load(agent), added)
      # 2. Live slice UN-ADVANCED (the commit failed → the actor kept the old slice).
      {:ok, %{state: after_live}} = Ezagent.Kind.SliceAccess.get_raw_slice(agent, :identity)
      assert after_live.caps == before_live.caps
      # 3. Snapshot unchanged — the write aborts BEFORE the snapshot upsert.
      {:ok, snapshot, _meta} = Ezagent.Kind.read_durable(agent, :identity)
      refute cap_present?(MapSet.to_list(snapshot.caps), added)

      # Restore the active epoch before teardown so the terminate/drain path is not
      # driven under a forced-unreadable epoch.
      Application.delete_env(:ezagent_domain_identity, :identity_cutover_force_read_error)
      Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, true)
      :ok = Ezagent.Kind.terminate(agent)
    end

    test "a live REVOKE under an unreadable epoch is refused; Store, snapshot, and live slice keep the cap" do
      agent = agent_uri("item2-revoke-unknown")
      keep = issued_cap(agent, :send)
      target = issued_cap(agent, :publish)

      {:ok, _pid} =
        Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: [keep, target]})

      wait_until_ready(agent)
      assert cap_present?(Store.load(agent), target)
      before_store = identity_keys(Store.load(agent))
      {:ok, %{state: before_live}} = Ezagent.Kind.SliceAccess.get_raw_slice(agent, :identity)

      Application.delete_env(:ezagent_domain_identity, :identity_cutover_active_override)
      Application.put_env(:ezagent_domain_identity, :identity_cutover_force_read_error, true)
      assert Ezagent.Identity.Cutover.status() == :unknown

      assert {:error, _} = EntityCaps.revoke(agent, target)

      # The cap is STILL present on all three planes — the revoke was refused.
      # 1. Store unchanged.
      assert identity_keys(Store.load(agent)) == before_store
      assert cap_present?(Store.load(agent), target)
      # 2. Live slice UN-ADVANCED.
      {:ok, %{state: after_live}} = Ezagent.Kind.SliceAccess.get_raw_slice(agent, :identity)
      assert after_live.caps == before_live.caps
      # 3. Snapshot unchanged.
      {:ok, snapshot, _meta} = Ezagent.Kind.read_durable(agent, :identity)
      assert cap_present?(MapSet.to_list(snapshot.caps), target)

      Application.delete_env(:ezagent_domain_identity, :identity_cutover_force_read_error)
      Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, true)
      :ok = Ezagent.Kind.terminate(agent)
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
               Store.sync_committed_identity(user, nil, %{
                 caps: MapSet.new(licensed_caps(user, [cap]))
               })

      refute Store.has_row?(user)

      agent = agent_uri("skip-ephemeral")

      assert :ok =
               Store.sync_committed_identity(agent, EphemeralHostKind, %{
                 caps: MapSet.new(licensed_caps(agent, [issued_cap(agent, :send)]))
               })

      refute Store.has_row?(agent)

      # The same slice on the direct-write path (nil kind_module) mirrors. Under
      # the test-env active epoch this is the AUTHORITATIVE post-epoch commit, so
      # the hook returns `{:ok, :authoritative}` (#189 PR-3 FINAL ITEM 1) — the
      # signal the actor-layer snapshot writer uses to keep a snapshot-projection
      # failure from being reported as a mutation failure.
      assert {:ok, :authoritative} =
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

  describe "write-boundary resurrection guard (#189 PR-2, codex F1)" do
    test "a license-missing mirror write lands revoked_unprovisioned, never active" do
      agent = agent_uri("guard-missing")
      # A cap set with NO self-license (just an ordinary issued cap).
      caps = [issued_cap(agent, :send)]

      assert :ok = Store.persist(agent, caps)
      assert Store.status(agent) == :revoked_unprovisioned
      assert Store.load(agent) == []
      # The row EXISTS (never left absent) — a later stale write can't recreate
      # it active.
      assert Store.has_row?(agent)
    end

    test "a current-valid self-license activates; a STALE (post-regenesis) one downgrades" do
      agent = agent_uri("guard-stale")
      # `licensed_caps/2` mints a CURRENT (gen-1) self-license.
      caps = licensed_caps(agent, [issued_cap(agent, :send)])

      assert :ok = Store.persist(agent, caps)
      assert Store.status(agent) == :active
      assert identity_keys(Store.load(agent)) == identity_keys(caps)

      # Bump the authority generation — the minted self-license is now STALE
      # (it verifies by PRESENCE but NOT `verify_against_current`).
      assert {:ok, _bumped} = Ezagent.Cap.Authority.regenesis(agent, :agent)
      assert Enum.any?(caps, &(Ezagent.Capability.action_of(&1) == :self_license))

      # The same (now stale) caps mirrored again → DOWNGRADE to
      # revoked_unprovisioned (the guard verifies against the current gen).
      assert :ok = Store.persist(agent, caps)
      assert Store.status(agent) == :revoked_unprovisioned
      assert Store.load(agent) == []
    end

    test "a mirror write NEVER upgrades a revoked_unprovisioned row (only reprovision does)" do
      agent = agent_uri("guard-no-upgrade")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, caps)

      assert :ok = Store.provision(agent, caps, receipt, actor: @system_actor)
      assert :ok = Store.revoke_provisioning(agent)
      assert Store.status(agent) == :revoked_unprovisioned

      # A shadow write with a fully current-valid license must NOT resurrect it.
      assert :ok = Store.persist(agent, caps)
      assert Store.status(agent) == :revoked_unprovisioned
      assert Store.load(agent) == []
    end

    test "a mirror write never overwrites a tombstoned row" do
      agent = agent_uri("guard-tombstone")
      assert :ok = Store.tombstone(agent)
      assert Store.status(agent) == :tombstoned

      assert :ok = Store.persist(agent, licensed_caps(agent, [issued_cap(agent, :send)]))
      assert Store.status(agent) == :tombstoned
      assert Store.load(agent) == []
    end

    test "provision REQUIRES a current self-license, not merely a valid receipt (finding 1(b))" do
      agent = agent_uri("provision-no-license")
      # Caps with NO self-license (an ordinary issued cap only) but a perfectly
      # valid, digest-bound receipt for exactly that set.
      caps = [issued_cap(agent, :send)]
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, caps)
      refute Store.has_current_self_license?(caps, agent)

      # A valid receipt attests to the cap-set DIGEST + actor, NOT to license
      # currency — so provision must still refuse to activate a license-missing
      # principal (codex impl-review finding 1: the provision path was a bypass).
      assert {:error, :no_current_self_license} =
               Store.provision(agent, caps, receipt, actor: @system_actor)

      refute Store.has_row?(agent)
      refute Store.status(agent) == :active
    end

    test "reprovision of a revoked principal REQUIRES a current self-license (finding 1(b))" do
      agent = agent_uri("reprovision-no-license")

      # Bring it to revoked_unprovisioned via a legitimate provision + revoke.
      good = licensed_caps(agent, [issued_cap(agent, :send)])

      assert :ok =
               Store.provision(
                 agent,
                 good,
                 ProvisioningReceipt.issue(agent, @system_actor, :provision, good),
                 actor: @system_actor
               )

      assert :ok = Store.revoke_provisioning(agent)
      assert Store.status(agent) == :revoked_unprovisioned

      # Reprovision with caps carrying NO current self-license: a valid receipt
      # is not enough — the revoked principal is NOT resurrected to active.
      bad = [issued_cap(agent, :join)]
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :reprovision, bad)
      refute Store.has_current_self_license?(bad, agent)

      assert {:error, :no_current_self_license} =
               Store.reprovision(agent, bad, receipt, actor: @system_actor)

      assert Store.status(agent) == :revoked_unprovisioned
      assert Store.load(agent) == []
    end
  end

  describe "tombstone monotonicity across the snapshot-clear hook (#189 PR-2, codex F5)" do
    test "identity_snapshot_cleared PRESERVES a tombstoned row" do
      agent = agent_uri("tombstone-preserve")
      assert :ok = Store.tombstone(agent)
      assert Store.status(agent) == :tombstoned

      # A routine snapshot clear must NOT delete the tombstone (that would let a
      # later restart look like a genuine creation and resurrect the principal).
      assert :ok = Store.identity_snapshot_cleared(agent)
      assert Store.has_row?(agent)
      assert Store.status(agent) == :tombstoned
    end

    test "identity_snapshot_cleared still clears a non-tombstoned (active) row" do
      agent = agent_uri("clear-active")
      assert :ok = Store.persist(agent, licensed_caps(agent, [issued_cap(agent, :send)]))
      assert Store.status(agent) == :active

      assert :ok = Store.identity_snapshot_cleared(agent)
      refute Store.has_row?(agent)
    end

    test "identity_snapshot_cleared PRESERVES a revoked_unprovisioned row (FIX 3 creation evidence)" do
      agent = agent_uri("clear-revoked")
      assert :ok = Store.persist(agent, licensed_caps(agent, [issued_cap(agent, :send)]))
      assert :ok = Store.revoke_provisioning(agent)
      assert Store.status(agent) == :revoked_unprovisioned

      # A routine snapshot clear must NOT delete the revoked_unprovisioned row:
      # it is durable creation+revocation evidence. Deleting it would leave the
      # URI absent, and a later restart WITHOUT authority history would then look
      # like a genuine creation and resurrect the principal.
      assert :ok = Store.identity_snapshot_cleared(agent)
      assert Store.has_row?(agent)
      assert Store.status(agent) == :revoked_unprovisioned
    end
  end

  describe "#189 PR-3 FIX 3 (cold-restart 5-state matrix — no state re-mints)" do
    # `ever_created_signal?/1` is the SOLE determinant of `:created` vs `:existed`
    # for an ephemeral principal at cold restart (`Kind.Server.create_freshness`).
    # `true` ⇒ `:existed` ⇒ the principal re-reads (never re-mints). Only a
    # genuine first creation (no store row AND no authority history) is `false`.
    test "active-current row ⇒ ever-created (existed)" do
      agent = agent_uri("state-active-current")
      assert :ok = Store.persist(agent, licensed_caps(agent, [issued_cap(agent, :send)]))
      assert Store.status(agent) == :active
      assert Store.ever_created_signal?(agent)
    end

    test "active-but-stale-generation row ⇒ ever-created (existed), not re-created" do
      agent = agent_uri("state-active-stale")
      assert :ok = Store.persist(agent, licensed_caps(agent, [issued_cap(agent, :send)]))
      # Rotate the signing generation: the store row stays `active` with a now
      # stale license; the restart must still classify `:existed`.
      assert {:ok, _authority} = Ezagent.Cap.Authority.regenesis(agent, :agent)
      assert Store.status(agent) == :active
      assert Store.ever_created_signal?(agent)
    end

    test "revoked_unprovisioned row ⇒ ever-created (existed)" do
      agent = agent_uri("state-revoked")
      assert :ok = Store.persist(agent, licensed_caps(agent, [issued_cap(agent, :send)]))
      assert :ok = Store.revoke_provisioning(agent)
      assert Store.status(agent) == :revoked_unprovisioned
      assert Store.ever_created_signal?(agent)
    end

    test "tombstoned row ⇒ ever-created (existed)" do
      agent = agent_uri("state-tombstoned")
      assert :ok = Store.tombstone(agent)
      assert Store.status(agent) == :tombstoned
      assert Store.ever_created_signal?(agent)
    end

    test "absent store row WITH authority history ⇒ ever-created (existed) — no resurrection" do
      agent = agent_uri("state-absent-authority")
      # Opening a self-license mints authority history (`kind_cap_authorities`)
      # but writes NO store row. This is the revoked-then-cleared ephemeral
      # worker: the durable creation fact survives ONLY in the authority history.
      _license = self_license(agent)
      refute Store.has_row?(agent)
      assert Ezagent.Cap.Authority.has_authority_history?(agent)

      # FIX 3: absence is NOT sufficient for `:created` when authority history
      # exists — it reports ever-created (`:existed`), so the restart re-reads and
      # is NOT re-minted a fresh generation.
      assert Store.ever_created_signal?(agent)
    end

    test "genuine first creation (no row, no authority history) ⇒ NOT ever-created (:created)" do
      agent = agent_uri("state-genuine-creation")
      refute Store.has_row?(agent)
      refute Ezagent.Cap.Authority.has_authority_history?(agent)
      refute Store.ever_created_signal?(agent)
    end

    test "adopt_absent_authority_history materializes an absent authority URI as revoked_unprovisioned" do
      agent = agent_uri("adopt-absent")
      _license = self_license(agent)
      refute Store.has_row?(agent)

      assert {:ok, :adopted} = Store.adopt_absent_authority_history(agent)
      assert Store.status(agent) == :revoked_unprovisioned
      assert Store.load(agent) == []

      # Idempotent — never re-adopts, never upgrades.
      assert {:ok, :present} = Store.adopt_absent_authority_history(agent)
      assert Store.status(agent) == :revoked_unprovisioned
    end

    test "adopt_absent_authority_history NEVER clobbers an existing active row" do
      agent = agent_uri("adopt-noclobber")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])
      assert :ok = Store.persist(agent, caps)
      assert Store.status(agent) == :active

      assert {:ok, :present} = Store.adopt_absent_authority_history(agent)
      # The live, valid principal is left exactly as it was — never downgraded.
      assert Store.status(agent) == :active
      assert cap_present?(Store.load(agent), Enum.at(caps, 1))
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

  defp v2_issued_cap(receiver, action) do
    v2_issued_cap(receiver, action, URI.new!("session://identity-caps-store/default/main"))
  end

  defp v2_issued_cap(receiver, action, target) do
    grant_id = Ecto.UUID.generate()

    unsigned = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: target,
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now(),
      signing_version: 2,
      grant_id: grant_id
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(unsigned.instance, :session)
    authority_signed_cap_as!(authority, @issuer, receiver, unsigned)
  end

  defp revoke_cap(receiver, cap) do
    attrs = %{
      grant_id: cap.grant_id,
      workspace_uri: receiver |> Ezagent.URI.workspace_of() |> Ezagent.URI.stable_key(),
      holder_uri: Ezagent.URI.stable_key(receiver),
      cap_identity_key:
        :crypto.hash(:sha256, :erlang.term_to_binary(Capability.identity_key(cap))),
      revoked_at: DateTime.utc_now(),
      target_uri: Ezagent.URI.stable_key(cap.instance),
      key_id: cap.key_id
    }

    case RevocationLedger.mark(attrs) do
      {:ok, _marker} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
    do:
      URI.new!(
        "entity://identity-caps-store/user/#{suffix}-#{System.unique_integer([:positive])}"
      )

  defp agent_uri(suffix),
    do:
      URI.new!(
        "entity://identity-caps-store/agent/#{suffix}-#{System.unique_integer([:positive])}"
      )

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
