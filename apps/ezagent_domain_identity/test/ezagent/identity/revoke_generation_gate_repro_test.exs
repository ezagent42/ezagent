defmodule Ezagent.Identity.RevokeGenerationGateReproTest do
  @moduledoc """
  ②-Q2 spec-mandated repro test (delivery-outbox final plan §Q2) — VERDICT
  ENCODED: the question was whether `revoke_cap_via_router/4`'s physical
  `remove_cap` is store-convergence cleanup the GENERATION gate backstops
  (plan lean (b)), or security-load-bearing so a lost delivery leaves a
  still-usable/still-readable cap (plan → (a)).

  VERDICT: (a). The GAP arm as originally committed PROVED a lost `:async`
  revoke leaves the cap usable + readable (the generation gate never covers
  `remove_cap` — no key_id bump happens on the revoke path), so the physical
  delete IS security-load-bearing. The fix (② P2(b)): the revoke FIRST
  deletes the cap from the holder's AUTHORITATIVE DURABLE STORE
  (`Ezagent.EntityCaps.revoke_persisted/2` — users: `users.caps_json` +
  identity-caps store + the user Kind's snapshot slice; non-users: the
  snapshot `:identity` slice + store + grantee index), synchronously and
  independent of target liveness; the `:remove_cap` dispatch degrades to a
  reconcile HINT. The GAP arm now asserts the fixed contract: a lost hint
  changes nothing — after restart + full ready-drain the cap is DENIED +
  HIDDEN because the store was deleted at revoke time.

  Two arms, both driving the REAL production revoke API
  (`Ezagent.Identity.Grant.revoke_cap_via_router/4`) and asserting through the
  REAL act-time gates dispatch uses:

    * usable? → `Ezagent.Cap.authorize/3`
      (principal gate + `Authority.verify_against_current/3`), NOT the
      process-dict `verify_current/2`.
    * readable? → `Ezagent.EntityCaps.GranteeIndex.grantees_of/4`
      (filters to the target's CURRENT active `key_id`).

  CONTROL — revoke is APPLIED (ready holder, :sync) → cap must become
  DENIED + HIDDEN. Proves the harness and the revoke work.

  GAP (fixed) — revoke is ACCEPTED then the hint is LOST before apply
  (holder goes not-ready, the accepted :async cast buffers volatilely, then
  the holder Kind is restarted: terminate + respawn + full ready-drain /
  outbox rehydrate) → the cap is STILL DENIED + HIDDEN, because
  `revoke_persisted/2` deleted it from the durable store at revoke time,
  before the hint was ever dispatched. (This simulates a Kind-process
  restart; `Kind.terminate/1` even DLQs the pending cast first, whereas a
  real BEAM crash drops the ETS buffer outright — strictly MORE lossy,
  never less.)

  Both CONTROL and GAP also assert the target authority `key_id` is UNCHANGED
  across the revoke, so the CONTROL denial is provably the physical delete (not
  an incidental generation bump) and the GAP survival is provably not masking a
  regenesis. CONTRAST shows the genuine generation mechanism the (b) rationale
  assumes — a regenesis `key_id` bump — which `revoke_cap_via_router` never does.
  """
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4, self_license_cap!: 2]

  alias Ezagent.Capability
  alias Ezagent.Cap.Authority
  alias Ezagent.EntityCaps
  alias Ezagent.EntityCaps.{GranteeIndex, Store}
  alias Ezagent.Identity.Grant

  @workspace URI.new!("workspace://team-alpha")
  @issuer URI.new!("entity://team-alpha/user/issuer")
  @admin Ezagent.URI.user(:system, :admin)

  test "CONTROL: an APPLIED revoke_cap_via_router denies + hides the cap" do
    target = session_target("control")
    {holder, pid} = spawn_holder("control-holder")
    cap = hold_cap_toward!(holder, target)

    # Baseline: the holder can act on and is discoverable for the target.
    assert usable?(holder, target), "baseline: cap should authorize before revoke"
    assert readable?(holder, target), "baseline: holder should appear in grantees_of"
    key_id_before = active_key_id(target)

    # Real production revoke, applied synchronously against a ready holder.
    assert :ok = Grant.revoke_cap_via_router(holder, cap, {:held_by, holder}, :sync)

    refute usable?(holder, target), "applied revoke MUST deny the cap"
    refute readable?(holder, target), "applied revoke MUST hide the holder from grantees_of"

    assert active_key_id(target) == key_id_before,
           "the denial is the PHYSICAL delete — revoke_cap_via_router does NOT bump the generation"

    terminate(holder, pid)
  end

  test "GAP (fixed): a LOST remove_cap hint still denies + hides the cap (durable store delete carries the revoke)" do
    target = session_target("gap")
    {holder, pid} = spawn_holder("gap-holder")
    cap = hold_cap_toward!(holder, target)

    assert usable?(holder, target), "baseline: cap should authorize before revoke"
    assert readable?(holder, target), "baseline: holder should appear in grantees_of"
    key_id_before = active_key_id(target)

    # Holder goes cold (the M-10 consume_join_entitlement condition: a not-ready
    # principal). The durable store delete commits SYNCHRONOUSLY here (the P2(b)
    # fix); the :async remove_cap hint cast is ACCEPTED (buffers volatilely) and
    # then LOST. NOTHING bumps a generation (no regenesis on the revoke path).
    # Asserting :ok proves the durable delete committed and the hint was
    # accepted, not short-circuited by a pre-dispatch error.
    :ok = Ezagent.ReadyGate.put(holder, :not_ready)
    assert :ok = Grant.revoke_cap_via_router(holder, cap, {:held_by, holder}, :async)

    # Restart — DOWN half: the holder Kind dies with its volatile buffer. The
    # detached cast is dead-lettered (:never_ready → DLQ sink: log/telemetry,
    # NOT a redelivery path). The durable holder store was ALREADY mutated by
    # revoke_persisted/2 (that is the fix); the lost hint changes nothing.
    terminate(holder, pid)
    assert eventually(fn -> not Process.alive?(pid) end), "holder Kind should be down (restart)"

    # Restart — UP half: bring the holder back and run the FULL cold-boot ready
    # path a real BEAM restart runs (outbox-hint rehydrate + ready-drain). If the
    # lost revoke reconverged via ANY non-outbox path, the cap would become
    # denied HERE. (A real BEAM restart presents a fresh volatile ReadyGate; our
    # in-process terminate left it :failed via mark_failed, so reset it to the
    # fresh-boot state the restart would show — mirrors the outbox cold-boot
    # test's rehydrate-then-drain.)
    {:ok, pid2} = Ezagent.SpawnRegistry.spawn(holder)
    :ok = Ezagent.ReadyGate.put(holder, :not_ready)
    :ok = Ezagent.Cap.DeliveryOutbox.rehydrate_hints()

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(holder),
               pid2
             )

    # The durable holder store was deleted at revoke time (read it DIRECTLY,
    # not the live-first loader) — and the holder's cold-boot restore source
    # (its snapshot identity slice) was cleaned too, so `Identity.activate/2`'s
    # snapshot ∪ caps_json union cannot resurrect the cap.
    refute holds_cap_in_durable_store?(holder, cap),
           "GAP (fixed): the durable holder store MUST NOT contain the revoked cap after restart+drain"

    # ...and the target generation was never bumped — so the denial below is
    # the durable delete, NOT a regenesis.
    assert active_key_id(target) == key_id_before,
           "GAP (fixed): key_id unchanged — the revoke path performed no generation bump"

    # Re-check through the same act-time gates dispatch uses.
    refute usable?(holder, target),
           "GAP (fixed): the revoked cap is DENIED after restart+respawn+drain — the durable delete survived the lost hint"

    refute readable?(holder, target),
           "GAP (fixed): the revoked holder is HIDDEN from grantees_of after restart+drain — the grantee index lost the row"

    terminate(holder, pid2)
  end

  test "CONTRAST: a genuine generation bump (regenesis) DOES deny + hide without any remove_cap" do
    target = session_target("contrast")
    {holder, pid} = spawn_holder("contrast-holder")
    _cap = hold_cap_toward!(holder, target)

    assert usable?(holder, target)
    assert readable?(holder, target)

    # This is the mechanism the plan's (b) rationale actually describes —
    # and it is NOT what revoke_cap_via_router does.
    assert {:ok, _authority} = Authority.regenesis(Ezagent.URI.instance(target), :session)

    refute usable?(holder, target), "regenesis MUST deny the stale-generation cap"
    refute readable?(holder, target), "regenesis MUST hide the stale-generation holder"

    terminate(holder, pid)
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

    assert eventually(fn -> holds_cap?(holder, cap) end),
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

  # Live-first view (setup readiness check): mirrors what dispatch loads.
  defp holds_cap?(holder, cap), do: cap_present?(EntityCaps.load(holder), cap)

  # DURABLE store, read directly (bypasses the live-first loader) — the exact
  # row a lost remove_cap would have deleted.
  defp holds_cap_in_durable_store?(holder, cap), do: cap_present?(Store.load(holder), cap)

  defp cap_present?(caps, cap) do
    Enum.any?(caps, fn c ->
      c.instance == cap.instance and c.action == cap.action and c.behavior == cap.behavior and
        c.grantee_uri == cap.grantee_uri
    end)
  end

  # The target authority's CURRENT active generation key_id (nil if none).
  defp active_key_id(target) do
    case Ezagent.Ecto.KindCapAuthority.active(
           Ezagent.URI.stable_key(Ezagent.URI.instance(target))
         ) do
      %{key_id: key_id} -> key_id
      _ -> nil
    end
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
