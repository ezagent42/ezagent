defmodule Ezagent.ActionSet.Session.ReconcileAfterLoadTest do
  @moduledoc """
  Membership-cap unification A1.3 (spec §4.4 / test 5) — `reconcile_after_load/2`
  SEEDS/HEALS the `:members` delivery projection from the authoritative member-cap
  holder set on `activate/2`.

  A1 is additive/behavior-preserving, so reconcile UNIONS (keeps every persisted
  member, ADDS cap-only holders) — it never evicts a roster-only entry (that would
  change delivery under the still-live ephemeral mint; eviction is an A2 concern).
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

  defp new_session(prefix, owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "#{prefix}-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  # Grant the member-cap directly (test process, so `:sync` is safe — the
  # session's data-owner resolution calls the live session Kind, no self-deadlock).
  defp grant_member_cap(member, session, granter) do
    cap =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session,
        Capability.workspace_of(session)
      )

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        member,
        cap,
        {:rule, :session_participation, granter},
        :sync
      )
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

  test "reconcile_after_load UNIONS — preserves a persisted roster-only member (A1 no-eviction)" do
    owner = confirmed_user("owner")
    session = new_session("reconcile-union", owner)
    member = confirmed_user("member")
    grant_member_cap(member, session, owner)

    roster_only = URI.new!("entity://system/user/roster-only-#{uniq()}")
    persisted = %{roster_only => %{online: true}}

    reconciled = Reconcile.reconcile_after_load(session, persisted)

    assert Map.has_key?(reconciled, member), "cap-holder ADDED"

    assert Map.has_key?(reconciled, roster_only),
           "roster-only member (no held cap) PRESERVED — A1 unions, never evicts"
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
