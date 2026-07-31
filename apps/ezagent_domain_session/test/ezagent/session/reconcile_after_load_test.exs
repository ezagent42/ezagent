defmodule Ezagent.ActionSet.Session.ReconcileAfterLoadTest do
  @moduledoc """
  Membership-cap unification A1.3 (spec §4.4 / test 5) — `reconcile_after_load/2`
  SEEDS/HEALS the `:members` delivery projection from the authoritative member-cap
  holder set on `activate/2`.

  M-8 is the strict cutover: after the migration gate proves every existing
  roster member holds the cap, reconcile evicts roster-only entries and adds
  cap-only holders. The projection therefore converges exactly to cap holders.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session.Reconcile
  alias Ezagent.Capability

  defp uniq, do: System.unique_integer([:positive])

  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  # A principal that HAS a durable self-license (so the effective-cap read's
  # all-or-nothing self-license gate passes) but whose Kind is NOT live, so an
  # async absorb parks in the durable `Cap.DeliveryOutbox` instead of landing in
  # its own store. That is the structural in-flight window of #192: the at-join
  # grant is `:async` OF NECESSITY — a synchronous grant inside `handle_join`
  # deadlocks session creation — and a not-yet-ready receiver is exactly the
  # #207/#1409 case the outbox was built to own.
  defp offline_principal(prefix) do
    uri = Ezagent.URI.worker("system", "#{prefix}-#{uniq()}")

    {:ok, pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})

    # Activation provisions the durable self-license; take the process down so
    # the member-cap absorb below cannot be applied and stays pending.
    :ok =
      DynamicSupervisor.terminate_child(
        EzagentDomainInstanceMessage.AgentSupervisor,
        pid
      )

    uri
  end

  defp new_session(prefix, owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "#{prefix}-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  defp worker_principal(prefix) do
    uri = Ezagent.URI.worker("system", "#{prefix}-#{uniq()}")

    {:ok, pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.AgentSupervisor,
          pid
        )
      end
    end)

    uri
  end

  # Grant the member-cap directly (test process, so `:sync` is safe — the
  # session's data-owner resolution calls the live session Kind, no self-deadlock).
  defp grant_member_cap(member, session, granter) do
    grant_cap(member, member_cap_over(session), granter)
  end

  defp member_cap_over(session) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :receive,
      session,
      Capability.workspace_of(session)
    )
  end

  # A BROAD, action-wildcard cap over the session (`action: :any`). Under
  # `Capability.matches?/2` this wildcard satisfies the concrete `:receive`
  # need (the BLOCKER), but its `identity_key/1` differs from the concrete
  # member-cap — so exact-identity reconcile must NOT treat it as a member-cap.
  # It is `rule_cap_bounded?` (concrete kind/behavior/instance), so it grants
  # via the ordinary participation rule.
  defp broad_session_cap_over(session) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :any,
      session,
      Capability.workspace_of(session)
    )
  end

  defp grant_cap(member, cap, _granter) do
    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        member,
        cap,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )
  end

  # An `action: :any` cap is a wildcard grant → it needs ADMIN authority (the
  # rule tag is rejected by `check_action_wildcard_grant_authorized/2`). This is
  # exactly the admin-genesis provenance the BLOCKER is about: a broad cap that
  # `matches?/2` admits. Grant it under the `{:genesis, admin}` authority.
  defp grant_broad_cap(member, cap) do
    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        member,
        cap,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )
  end

  test "P1/#192: a member whose cap is still IN FLIGHT (pending in the delivery outbox) IS projected as a member" do
    owner = confirmed_user("inflight-owner")
    session = new_session("inflight", owner)
    member = offline_principal("inflight-member")
    ws = Capability.workspace_of(session)
    target_key = Capability.identity_key(member_cap_over(session))

    {:ok, artifact} =
      Ezagent.Identity.Grant.issue_cap(
        member,
        member_cap_over(session),
        {:admin, Ezagent.Entity.User.admin_uri()}
      )

    :ok = Ezagent.Identity.absorb_cap(member, artifact)

    # PRECONDITION — the artifact is genuinely IN FLIGHT: durably owned by the
    # outbox, NOT yet in the holder's own (landed) set. This is exactly the
    # state the old `EntityCaps.load/1`-based projection could not see, so this
    # test is red before the fix and green after.
    assert {:ok, pending} = Ezagent.Cap.DeliveryOutbox.list_pending_absorb_caps(member)
    assert Enum.any?(pending, &(Capability.identity_key(&1) == target_key))

    refute member
           |> Ezagent.EntityCaps.load()
           |> Enum.any?(&(Capability.identity_key(&1) == target_key))

    # BEHAVIOUR UNDER TEST — the projection counts the in-flight holder, so the
    # member is not dropped from `Resolver`'s fan-out during the window. For an
    # AGENT member that drop is permanent (delivery-driven, no history poll, no
    # message-level catch-up).
    assert Reconcile.member_cap_holder?(member, session, ws)
  end

  test "reconcile_after_load heals cap-only drift — a member-cap holder missing from the projection is ADDED [test 5]" do
    owner = confirmed_user("owner")
    session = new_session("reconcile", owner)
    member = confirmed_user("member")
    grant_member_cap(member, session, owner)

    reconciled = Reconcile.reconcile_after_load(session, %{})

    assert Map.has_key?(reconciled, member),
           "reconcile must SEED the projection from the held member-cap (cap-only drift healed)"
  end

  test "T4: reconcile_after_load EVICTS a persisted roster-only member after migration cutover" do
    owner = confirmed_user("owner")
    session = new_session("reconcile-union", owner)
    member = confirmed_user("member")
    grant_member_cap(member, session, owner)

    roster_only = URI.new!("entity://system/user/roster-only-#{uniq()}")
    persisted = %{roster_only => %{online: true}}

    reconciled = Reconcile.reconcile_after_load(session, persisted)

    assert Map.has_key?(reconciled, member), "cap-holder ADDED"

    refute Map.has_key?(reconciled, roster_only),
           "roster-only member holds no authority and must be evicted"
  end

  test "T6/worker: a worker cap-holder missing from the roster is enumerated and added" do
    owner = confirmed_user("worker-owner")
    session = new_session("reconcile-worker", owner)
    worker = worker_principal("member-worker")
    grant_member_cap(worker, session, owner)

    reconciled = Reconcile.reconcile_after_load(session, %{})

    assert Map.has_key?(reconciled, worker)
  end

  test "T6/anon: an anonymous user cap-holder missing from the roster is enumerated and added" do
    owner = confirmed_user("guest-owner")
    session = new_session("reconcile-anon", owner)
    assert {:ok, anon} = Ezagent.Socialware.AnonUser.mint(session)
    assert :ok = Ezagent.Entity.spawn_principal(anon)
    grant_member_cap(anon, session, owner)

    reconciled = Reconcile.reconcile_after_load(session, %{})

    assert Map.has_key?(reconciled, anon)
  end

  test "reconcile_after_load never crashes on ws candidates lacking the cap; returns a map [rescue/graceful]" do
    owner = confirmed_user("owner")
    session = new_session("reconcile-graceful", owner)
    noncap = confirmed_user("noncap")

    reconciled = Reconcile.reconcile_after_load(session, %{})

    assert is_map(reconciled), "reconcile must return a map without crashing"

    refute Map.has_key?(reconciled, noncap),
           "a ws user WITHOUT the member-cap must NOT be added to the projection"
  end

  test "reconcile uses EXACT member-cap identity — a BROAD :any cap holder is NOT reconciled, a concrete member-cap holder IS [BLOCKER refutation]" do
    owner = confirmed_user("owner")
    session = new_session("reconcile-exact", owner)

    # Both candidates live in the same workspace so BOTH are enumerated by the
    # candidate scan — proving the discrimination happens in the predicate, not
    # by one holder simply never being reached.
    broad_holder = confirmed_user("broad")
    grant_broad_cap(broad_holder, broad_session_cap_over(session))

    concrete_holder = confirmed_user("concrete")
    grant_member_cap(concrete_holder, session, owner)

    reconciled = Reconcile.reconcile_after_load(session, %{})

    assert Map.has_key?(reconciled, concrete_holder),
           "the EXACT member-cap holder must be reconciled into :members"

    refute Map.has_key?(reconciled, broad_holder),
           "a broad action-:any cap holder must NOT be reconciled — `matches?/2` " <>
             "would wrongly admit it; exact `identity_key/1` must reject it (BLOCKER)"
  end

  test "member_cap_holder?/3 is exact — true for the concrete cap, false for a broad :any cap [BLOCKER unit]" do
    owner = confirmed_user("owner")
    session = new_session("holder-exact", owner)
    ws = Capability.workspace_of(session)

    concrete_holder = confirmed_user("concrete")
    grant_member_cap(concrete_holder, session, owner)

    broad_holder = confirmed_user("broad")
    grant_broad_cap(broad_holder, broad_session_cap_over(session))

    assert Reconcile.member_cap_holder?(concrete_holder, session, ws),
           "holds the EXACT member-cap → true"

    refute Reconcile.member_cap_holder?(broad_holder, session, ws),
           "holds only a broad action-:any cap → false (exact identity, not matches?/2)"
  end

  test "activate/2 wires reconcile — returns the projection healed from the held cap [test 5 wiring]" do
    owner = confirmed_user("owner")
    session = new_session("reconcile-activate", owner)
    member = confirmed_user("member")

    # Cap present, but the member is absent from the projection passed to activate
    # (cap-only drift on cold load).
    grant_member_cap(member, session, owner)

    # activate/2 (the Session behavior's Lifecycle hook) MUST invoke reconcile and
    # return the healed `:members`. Called directly with the cold-load state +
    # `self_uri` ctx the runtime supplies — deterministic, no respawn timing.
    assert {:ok, ret} =
             Ezagent.ActionSet.Session.activate(%{members: %{}}, %{self_uri: session})

    assert Map.has_key?(ret.members, member),
           "activate/2 must reconcile the projection from the held member-cap"
  end
end
