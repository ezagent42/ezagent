defmodule Ezagent.Identity.RevokeDurabilityTest do
  @moduledoc """
  ② P2(c) — the durable-revoke resurrection suite (codex adversarial review,
  must-fixes #1/#2/#3). Each test pins one resurrection path the pre-P2(c)
  revoke left open and FAILS on the old code:

    1. **Pending grant deliveries** (must-fix #1) — a `:store_cap` /
       `:absorb_cap` grant buffered in the delivery outbox while the holder
       is not-ready used to survive the revoke and drain on the next restart,
       resurrecting the cap. The durable revoke now CANCELS matching pending
       deliveries (`:cancelled` terminal status), so the drain skips them.
    2. **Stale `caps_json` projection** (must-fix #2) — post-epoch the
       `caps_json` delete was best-effort: a projection failure returned
       `:ok` and the cold-boot invariant-20 union read the stale projection
       back into the live slice. The revoke now fails CLOSED on a projection
       error (and its read-modify-write sources the authoritative Store),
       and the revocation fence drops the stale artifact at boot.
    3. **Stale live writer** (must-fix #3) — a live holder that missed the
       `:remove_cap` hint keeps the cap in memory; its next whole-state
       commit re-presents the artifact to the authoritative Store + grantee
       index. The monotone revocation tombstone
       (`Ezagent.EntityCaps.Revocations`) fences every Store write boundary
       — while a genuine RE-GRANT (fresh `granted_at`, stamped by
       `Cap.issue/3` after the watermark) passes.
  """

  use EzagentCore.DataCase, async: false

  import Ecto.Query

  import Ezagent.Test.CapHelper,
    only: [authority_signed_cap_as!: 4, self_license_cap!: 2]

  alias Ezagent.{Capability, EntityCaps}
  alias Ezagent.Cap.{Authority, Delivery}
  alias Ezagent.Cap.DeliveryOutbox
  alias Ezagent.EntityCaps.{GranteeIndex, Store, UserStore}
  alias Ezagent.Identity.Grant
  alias EzagentCore.Repo

  @workspace URI.new!("workspace://team-alpha")
  @issuer URI.new!("entity://team-alpha/user/issuer")
  @admin Ezagent.URI.user(:system, :admin)

  # ── must-fix #1: pending grant deliveries must not resurrect ─────────────

  test "pending store_cap + absorb_cap deliveries are CANCELLED by the durable revoke and never drain" do
    workspace_name = "ws-pending-#{u()}"
    workspace = Ezagent.URI.workspace(workspace_name)
    {:ok, _pid} = Ezagent.Workspace.create(workspace_name, %{})

    {holder, pid} = spawn_holder("pending-grant-revoke")
    :ok = Ezagent.ReadyGate.put(holder, :not_ready)

    cap =
      Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :list_members,
        workspace,
        workspace
      )

    # A pre-issued artifact for the absorb producer (same cap identity as the
    # grant below — `identity_key/1` excludes provenance/signature).
    {:ok, artifact} = Grant.issue_cap(holder, cap, {:admin, @admin})

    # Buffer BOTH grant-side producers in the durable outbox (holder
    # not-ready): the P2(a) `:identity_grant` `:store_cap` row and the
    # `:identity_absorb` `:absorb_cap` row.
    assert :ok = Ezagent.Identity.absorb_cap(holder, artifact)

    assert :ok =
             Grant.grant_cap_via_router(holder, cap, {:admin, @admin}, :async)

    pending = pending_deliveries(holder)
    assert Enum.sort(Enum.map(pending, & &1.op)) == [:absorb_cap, :store_cap]
    assert DeliveryOutbox.pending_target?(holder)

    # The durable revoke: the holder is not-ready, so the :sync live hint
    # cannot apply — but the durable half commits (tombstone + cancels +
    # plane deletes) and the return DISTINGUISHES that (must-fix #5 shape).
    assert {:ok, {:hint_failed, _reason}} =
             Grant.revoke_cap_via_router(holder, cap, {:admin, @admin}, :sync)

    # BOTH pending grant deliveries are tombstoned :cancelled (never deleted —
    # the ledger stays auditable), and the ETS ready-hint is dropped.
    assert pending_deliveries(holder) == []

    cancelled = deliveries_with_status(holder, "cancelled")
    assert Enum.sort(Enum.map(cancelled, & &1.op)) == [:absorb_cap, :store_cap]
    refute DeliveryOutbox.pending_target?(holder)

    # Restart: the holder comes ready and the full ready-drain runs. The
    # cancelled rows MUST NOT deliver — the cap never materializes anywhere.
    :ok = Ezagent.ReadyGate.mark_ready(holder)
    assert :ok = DeliveryOutbox.rehydrate_hints()
    assert :ok = DeliveryOutbox.drain_target(holder)
    # Give any (wrongly) dispatched cast a window to land before denying.
    Process.sleep(150)

    refute identity_present?(EntityCaps.load(holder), cap),
           "a cancelled pending grant MUST NOT drain into the live slice after restart"

    refute identity_present?(Store.load(holder), cap),
           "a cancelled pending grant MUST NOT drain into the durable Store after restart"

    refute identity_present?(UserStore.load(holder), cap),
           "a cancelled pending grant MUST NOT drain into caps_json after restart"

    terminate(holder, pid)
  end

  # ── must-fix #2: stale caps_json projection must fail the revoke ─────────

  test "a failed caps_json projection fails the revoke (fail-closed); the fence blocks the cold-boot union" do
    target = session_target("stale-caps-json")
    {holder, pid} = spawn_holder("stale-caps-json")
    cap = hold_cap_toward!(holder, target)

    assert usable?(holder, target), "baseline: cap should authorize before revoke"

    # Force the post-epoch `caps_json` PROJECTION to fail after the
    # authoritative Store delete commits (TEST-ONLY seam; a real projection
    # outage is not reproducible in the sandbox).
    Application.put_env(
      :ezagent_domain_identity,
      :p4_forced_caps_json_failure_uris,
      [URI.to_string(holder)]
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_identity, :p4_forced_caps_json_failure_uris)
    end)

    # OLD code returned `:ok` here (projection failure swallowed) and the
    # cold-boot union resurrected the cap. NEW code fails CLOSED.
    assert {:error, {:caps_json_projection_failed, _}} =
             Grant.revoke_cap_via_router(holder, cap, {:held_by, holder}, :sync)

    # The authoritative Store delete committed BEFORE the projection failed...
    refute cap_present?(Store.load(holder), cap),
           "the authoritative Store delete must commit even when the projection fails"

    # ...while the projection AND the snapshot cleanup did not run — both
    # restore sources still hold the cap (the exact pre-P2(c) resurrection
    # setup).
    assert cap_present?(UserStore.load(holder), cap),
           "setup: caps_json must still hold the cap (projection failed)"

    assert snapshot_holds_cap?(holder, cap),
           "setup: the snapshot must still hold the cap (snapshot delete never ran)"

    # Clear the forced outage BEFORE the cold boot — the boot's filtered
    # re-persist must be able to converge the projection (the seam's only
    # target was the revoke's authoritative projection write).
    Application.delete_env(:ezagent_domain_identity, :p4_forced_caps_json_failure_uris)

    # Cold boot: the invariant-20 union reads BOTH stale restore sources; the
    # revocation fence must drop the tombstoned artifact.
    terminate(holder, pid)
    assert eventually(fn -> not Process.alive?(pid) end), "holder Kind should be down"

    {:ok, pid2} = Ezagent.SpawnRegistry.spawn(holder)
    :ok = Ezagent.ReadyGate.put(holder, :not_ready)
    :ok = DeliveryOutbox.rehydrate_hints()

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(holder),
               pid2
             )

    refute cap_present?(EntityCaps.load(holder), cap),
           "the cold-boot union MUST NOT resurrect the cap from stale caps_json/snapshot"

    refute usable?(holder, target), "the revoked cap stays DENIED after the cold boot"
    refute readable?(holder, target), "the revoked holder stays HIDDEN after the cold boot"
    refute cap_present?(Store.load(holder), cap), "the Store stays clean after the cold boot"

    # The boot's filtered re-persist CONVERGES the stale projection.
    assert eventually(fn -> not cap_present?(UserStore.load(holder), cap) end),
           "the cold boot must converge caps_json to the fenced set"

    # Fail-closed retry: with the outage cleared, the idempotent revoke
    # completes (returns cleanly — the cap is already gone everywhere).
    Application.delete_env(:ezagent_domain_identity, :p4_forced_caps_json_failure_uris)

    assert :ok = Grant.revoke_cap_via_router(holder, cap, {:held_by, holder}, :sync)

    terminate(holder, pid2)
  end

  # ── must-fix #3: stale live writer vs the monotone fence ─────────────────

  test "a stale whole-state Store write cannot re-add a tombstoned cap; a fresh re-grant passes the watermark" do
    target = session_target("stale-writer")
    holder = Ezagent.URI.new!("entity://team-alpha/agent/stale-writer-#{u()}")
    license = self_license_cap!(holder, :agent)
    cap = member_cap_toward!(holder, target)

    # The holder is durably established with the cap (store + grantee index).
    assert :ok = Store.persist(holder, [license, cap])
    assert cap_present?(Store.load(holder), cap)
    assert readable?(holder, target)

    # The durable revoke (no live Kind, no snapshot — the store-only plane,
    # the `:ephemeral`-principal arm of `revoke_persisted/2`).
    assert :ok = EntityCaps.revoke_persisted(holder, cap)
    refute cap_present?(Store.load(holder), cap)
    refute readable?(holder, target)

    # STALE WRITER — the still-live holder (which missed the hint) commits an
    # unrelated mutation: its whole-state write re-presents the pre-revoke
    # artifact (same identity, pre-watermark `granted_at`) to the
    # authoritative Store. The fence MUST filter it — and the grantee index
    # (re-derived in the same transaction) must stay hidden.
    assert :ok = Store.persist(holder, [license, cap])

    refute cap_present?(Store.load(holder), cap),
           "the fence MUST filter the stale artifact out of the Store write"

    refute readable?(holder, target),
           "the fence MUST keep the stale artifact out of the grantee index"

    # The tombstone is monotone and the row survives (the holder is still
    # active, minus the revoked cap).
    assert cap_present?(Store.load(holder), license),
           "the holder's other caps (self-license) survive the fence"

    # FRESH RE-GRANT — `Cap.issue/3` re-stamps `granted_at` after the
    # watermark, so a genuine re-grant of the SAME cap identity passes the
    # fence (the fence is a watermark, not a permanent ban).
    fresh = member_cap_toward!(holder, target)
    assert :ok = Store.persist(holder, [license, fresh])

    assert cap_present?(Store.load(holder), fresh),
           "a genuine re-grant (granted_at after the watermark) MUST pass the fence"

    assert readable?(holder, target)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp session_target(suffix) do
    uri = Ezagent.URI.new!("session://team-alpha/boards/#{suffix}-#{u()}")
    {:ok, _authority} = Authority.open(uri, :session)
    uri
  end

  defp spawn_holder(prefix) do
    holder = Ezagent.URI.user("team-alpha", "#{prefix}-#{u()}")
    {:ok, _user} = Ezagent.Users.create(holder, nil, [])
    {:ok, pid} = Ezagent.SpawnRegistry.spawn(holder)
    assert :ok = Ezagent.ReadyGate.await(holder, 2_000)
    {holder, pid}
  end

  # Give `holder` a real target-signed cap toward `target`, durably present in
  # both its live slice and its durable store, plus a current self-license so it
  # clears the Cap.authorize principal gate. Returns the signed cap.
  defp hold_cap_toward!(holder, target) do
    cap = member_cap_toward!(holder, target)
    :ok = Store.persist(holder, [self_license_cap!(holder, :user), cap])
    :ok = Ezagent.Identity.absorb_cap(holder, cap)

    assert eventually(fn -> cap_present?(EntityCaps.load(holder), cap) end),
           "setup: cap should be held after absorb"

    cap
  end

  defp member_cap_toward!(holder, target) do
    {:ok, authority} = Authority.open(Ezagent.URI.instance(target), :session)

    requested = %Capability{
      kind: :session,
      behavior: :example,
      action: :receive,
      instance: Ezagent.URI.instance(target),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now()
    }

    authority_signed_cap_as!(authority, @issuer, holder, requested)
  end

  defp needed_for(target) do
    %{
      kind: :session,
      behavior: :example,
      action: :receive,
      instance: Ezagent.URI.instance(target),
      workspace_uri: @workspace
    }
  end

  defp usable?(holder, target) do
    caps = EntityCaps.load(holder)
    match?({:ok, %Capability{}}, Ezagent.Cap.authorize(holder, caps, needed_for(target)))
  end

  defp readable?(holder, target) do
    holder in GranteeIndex.grantees_of(Ezagent.URI.instance(target), @admin, admin_caps())
  end

  defp pending_deliveries(holder) do
    Repo.all(
      from(delivery in Delivery,
        where: delivery.target_uri == ^URI.to_string(holder) and delivery.status == :pending,
        order_by: [asc: delivery.op]
      )
    )
  end

  defp deliveries_with_status(holder, status) do
    Repo.all(
      from(delivery in Delivery,
        where: delivery.target_uri == ^URI.to_string(holder) and delivery.status == ^status,
        order_by: [asc: delivery.op]
      )
    )
  end

  defp snapshot_holds_cap?(holder, cap) do
    case Ezagent.SnapshotStore.latest(holder) do
      {:ok, %{state: %{identity: identity}}} when is_map(identity) ->
        caps =
          case identity do
            %{state: %{caps: %MapSet{} = caps}} -> MapSet.to_list(caps)
            %{caps: %MapSet{} = caps} -> MapSet.to_list(caps)
            _ -> []
          end

        cap_present?(caps, cap)

      _ ->
        false
    end
  end

  defp cap_present?(caps, cap) do
    Enum.any?(caps, fn c ->
      c.instance == cap.instance and c.action == cap.action and c.behavior == cap.behavior and
        c.grantee_uri == cap.grantee_uri
    end)
  end

  # Identity-axes presence (kind/behavior/action/instance/workspace) — used
  # when the reference cap is an unsigned SHAPE (nil `grantee_uri`), where
  # `cap_present?/2`'s grantee comparison would never match.
  defp identity_present?(caps, cap) do
    Enum.any?(caps, fn c ->
      c.kind == cap.kind and c.behavior == cap.behavior and c.action == cap.action and
        c.instance == cap.instance and c.workspace_uri == cap.workspace_uri
    end)
  end

  defp admin_caps do
    MapSet.new([
      %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: @admin,
        granted_at: DateTime.utc_now()
      }
    ])
  end

  defp terminate(holder, pid) do
    if Process.alive?(pid), do: Ezagent.Kind.terminate(holder)
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp u, do: System.unique_integer([:positive])
end
