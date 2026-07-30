defmodule Ezagent.EntityCaps.StoreBackfillTest do
  @moduledoc """
  #189 PR-2 D1 — the dedicated, row-locked `Store.backfill/2` migration
  transition + its resurrection guard (codex spec-review F1).

  The headline is the **fail-before / pass-after** resurrection proof: a
  principal whose LEGACY source still carries a STALE (revoked-generation)
  self-license must land `revoked_unprovisioned`, NEVER `active`. A naive
  presence-based copy ("caps carry a `:self_license` ⇒ active") would resurrect
  exactly that principal — the guard verifies the license against the URI's
  CURRENT authority generation instead.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.Capability
  alias Ezagent.EntityCaps.Store
  alias Ezagent.Identity.ProvisioningReceipt

  @workspace URI.new!("workspace://identity-caps-backfill")
  @issuer URI.new!("entity://identity-caps-backfill/user/issuer")
  @system_actor URI.new!("entity://system/user/provisioner")

  describe "resurrection guard (fail-before / pass-after)" do
    test "a STALE (revoked-generation) legacy self-license lands revoked_unprovisioned, NOT active" do
      agent = agent_uri("stale-license")
      # A CURRENT self-license at mint time…
      stale_caps = licensed_caps(agent, [issued_cap(agent, :send)])

      # …then a revocation bumps the authority generation. The license now sits
      # STALE in the legacy source (revocation never purges it — codex F1).
      assert {:ok, _bumped} = Ezagent.Cap.Authority.regenesis(agent, :agent)

      # FAIL-BEFORE: the self-license IS present in the legacy caps — a naive
      # presence-based backfill ("has a :self_license ⇒ active") WOULD activate
      # this revoked principal (the resurrection bug).
      assert Enum.any?(stale_caps, &(Capability.action_of(&1) == :self_license))
      # PASS-AFTER: the guard verifies against the CURRENT generation → not valid.
      refute Store.has_current_self_license?(stale_caps, agent)

      assert {:ok, :revoked_unprovisioned} = Store.backfill(agent, stale_caps)
      assert Store.status(agent) == :revoked_unprovisioned
      assert Store.load(agent) == []
      # Never left absent — a durable revoked row blocks a later stale mirror
      # write from recreating it active.
      assert Store.has_row?(agent)
    end

    test "a CURRENT-valid legacy self-license backfills active with matching caps (grandfathered)" do
      agent = agent_uri("current-license")
      caps = licensed_caps(agent, [issued_cap(agent, :send), issued_cap(agent, :join)])

      assert {:ok, :active} = Store.backfill(agent, caps)
      assert Store.status(agent) == :active
      assert identity_keys(Store.load(agent)) == identity_keys(caps)
      # Grandfathered activation — the second legitimate `active` proof (codex
      # F5): a current-valid self-license, no provisioning receipt required.
      assert is_nil(Store.fetch(agent).provisioning_receipt)
    end
  end

  describe "monotonicity + idempotence" do
    test "backfill NEVER upgrades a revoked_unprovisioned row, even with a valid license" do
      agent = agent_uri("no-upgrade")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])
      receipt = ProvisioningReceipt.issue(agent, @system_actor, :provision, caps)

      assert :ok = Store.provision(agent, caps, receipt, actor: @system_actor)
      assert :ok = Store.revoke_provisioning(agent)

      # Even though `caps` carries a current-valid license, backfill must not
      # resurrect a store-side revoked decision.
      assert {:ok, :revoked_unprovisioned} = Store.backfill(agent, caps)
      assert Store.status(agent) == :revoked_unprovisioned
    end

    test "backfill preserves a tombstoned row" do
      agent = agent_uri("tombstone")
      assert :ok = Store.tombstone(agent)

      assert {:ok, :tombstoned} = Store.backfill(agent, licensed_caps(agent, []))
      assert Store.status(agent) == :tombstoned
    end

    test "backfill DOWNGRADES an existing license-invalid active row" do
      agent = agent_uri("downgrade")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])

      # Seed an active row via the mirror path.
      assert :ok = Store.persist(agent, caps)
      assert Store.status(agent) == :active

      # Revoke → the seeded license is now stale-gen; a re-run of the backfill
      # from the (still-stale) legacy caps downgrades the active row.
      assert {:ok, _bumped} = Ezagent.Cap.Authority.regenesis(agent, :agent)
      assert {:ok, :revoked_unprovisioned} = Store.backfill(agent, caps)
      assert Store.status(agent) == :revoked_unprovisioned
    end

    test "backfill is idempotent for a current-valid principal" do
      agent = agent_uri("idempotent")
      caps = licensed_caps(agent, [issued_cap(agent, :send)])

      assert {:ok, :active} = Store.backfill(agent, caps)
      assert {:ok, :active} = Store.backfill(agent, caps)
      assert Store.status(agent) == :active
      assert identity_keys(Store.load(agent)) == identity_keys(caps)
    end
  end

  describe "verify/write race (codex impl-review finding 1(c))" do
    test "a regenesis interleaving mid-transition lands revoked, proving verify-inside-txn" do
      agent = agent_uri("verify-race")
      # A CURRENT self-license at mint time (authority generation 1).
      caps = licensed_caps(agent, [issued_cap(agent, :send)])
      assert Store.has_current_self_license?(caps, agent)

      # The TEST-ONLY seam fires a regenesis DURING the persist transaction —
      # AFTER the identity row is locked, BEFORE the self-license is verified.
      #
      # FAIL-BEFORE: pre-fix, `licensed?` was computed BEFORE `Repo.transaction`,
      # so a mid-transition regenesis could not affect it → the row would land
      # `active` with a now-stale license (the resurrection race).
      # PASS-AFTER: the verify runs INSIDE the transaction (under the
      # authority-row lock), sees the bumped generation, and lands
      # revoked_unprovisioned.
      test_pid = self()

      hook = fn %URI{} = uri ->
        # regenesis is not idempotent (each call bumps a generation) — fire once.
        if Process.get(:raced) == nil do
          Process.put(:raced, true)
          assert {:ok, _bumped} = Ezagent.Cap.Authority.regenesis(uri, :agent)
          send(test_pid, :regenesis_fired)
        end

        :ok
      end

      Application.put_env(:ezagent_domain_identity, :p2_verify_race_hook, hook)

      try do
        assert :ok = Store.persist(agent, caps)
        assert_received :regenesis_fired
        assert Store.status(agent) == :revoked_unprovisioned
        assert Store.load(agent) == []
      after
        Application.delete_env(:ezagent_domain_identity, :p2_verify_race_hook)
        Process.delete(:raced)
      end
    end
  end

  describe "legacy / unsigned caps (canary cutover-backfill catch #2, #213)" do
    test "backfill over a pre-#1399 signature-less cap does NOT crash (encode_caps KeyError)" do
      agent = agent_uri("legacy-encode")
      # A pre-#1399 legacy cap: a struct-shaped map MISSING the
      # signature/key_id/grantee_uri keys — the exact shape `binary_to_term`
      # reconstructs from a durable `:identity` slice snapshotted before the
      # cap-signing trio (2026-07-14).
      legacy = legacy_unsigned(issued_cap(agent, :send))
      refute Map.has_key?(legacy, :signature)

      # FAIL-BEFORE: `Store.backfill/2`'s `encode_caps` raised
      # `(KeyError) key :signature not found`, crashing the cutover backfill.
      # PASS-AFTER: it completes (no self-license present → revoked).
      assert {:ok, :revoked_unprovisioned} = Store.backfill(agent, [legacy])
    end

    test "an entity whose ONLY self-license is UNSIGNED backfills revoked_unprovisioned, NEVER active" do
      # Control: a SIGNED self-license → active.
      signed_agent = agent_uri("signed-self-license")
      assert {:ok, :active} = Store.backfill(signed_agent, [self_license(signed_agent)])

      # The SAME shape of license, minus its signature: an UNSIGNED self-license
      # (the trio's keys absent — the legacy snapshot shape). The authority is
      # freshly current, so the ONLY reason it must not activate is the missing
      # signature.
      agent = agent_uri("unsigned-self-license")
      unsigned_license = legacy_unsigned(self_license(agent))
      refute Map.has_key?(unsigned_license, :signature)

      # SECURITY INVARIANT: unsigned ≠ valid license — `verify_against_current`
      # fails closed on the absent signature key.
      refute Store.has_current_self_license?([unsigned_license], agent)
      assert {:ok, :revoked_unprovisioned} = Store.backfill(agent, [unsigned_license])
      assert Store.status(agent) == :revoked_unprovisioned
    end

    test "a mixed signed + unsigned cap list backfills active on the valid self-license and round-trips" do
      agent = agent_uri("mixed")
      caps = [self_license(agent), legacy_unsigned(issued_cap(agent, :send))]

      # The valid signed self-license grants `active`; the signature-less
      # sibling neither crashes encode nor is treated as a license.
      assert {:ok, :active} = Store.backfill(agent, caps)
      assert Store.status(agent) == :active
      # Both caps (incl. the signature-less one) round-trip through caps_json.
      assert identity_keys(Store.load(agent)) == identity_keys(caps)
    end
  end

  # -------------------------------------------------------------------
  # Helpers (mirror store_test.exs)
  # -------------------------------------------------------------------

  # Strip the #1399 cap-signing trio's keys to reproduce a pre-signing
  # `binary_to_term`'d snapshot cap: a struct-shaped map that MATCHES
  # `%Capability{}` (only `:__struct__` checked) yet lacks those keys.
  defp legacy_unsigned(%Capability{} = cap),
    do: Map.drop(cap, [:signature, :key_id, :grantee_uri])

  defp issued_cap(receiver, action) do
    unsigned = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: URI.new!("session://identity-caps-backfill/default/main"),
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

  defp agent_uri(suffix),
    do:
      URI.new!(
        "entity://identity-caps-backfill/agent/#{suffix}-#{System.unique_integer([:positive])}"
      )

  defp identity_keys(caps) do
    caps
    |> Enum.map(&Capability.identity_key/1)
    |> MapSet.new()
  end
end
