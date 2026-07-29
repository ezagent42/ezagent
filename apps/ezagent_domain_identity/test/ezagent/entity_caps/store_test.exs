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

    test "a shadow-write failure never rolls back the authoritative caps_json write (logged, not silent)" do
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
               Store.provision(agent, good, ProvisioningReceipt.issue(agent, @system_actor, :provision, good),
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
