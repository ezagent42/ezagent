defmodule Ezagent.Session.SocialwareReadHeldCapTest do
  @moduledoc """
  Membership-cap unification A2.3 (spec test 22 / R1.1) — the socialware READ
  predicate authorizes a non-owner reader on the caller's HELD member-cap over the
  session (read LIVE, provenance-filtered), NOT merely on presence in the roster
  projection. So a revoked ex-member with a lingering (stale) roster entry is
  denied IMMEDIATELY — the same "held-cap, not projection" story as the receive
  gate, sharing the ONE `MemberReceive.holds_member_cap_over?/2` predicate.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Session.Membership

  defp uniq, do: System.unique_integer([:positive])

  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp session_uri, do: URI.new!("session://system/default/read-#{uniq()}")

  defp grant_member_cap(member, session, _granter) do
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
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )

    # The :sync grant lands in the live slice; give the snapshot a beat if needed.
    :ok
  end

  defp chat_slice(owner, member), do: %{owner_uri: owner, members: %{member => %{online: true}}}

  test "ex-member (member-cap absent) still in the stale roster is DENIED (test 22)" do
    owner = confirmed_user("owner")
    member = confirmed_user("member")
    session = session_uri()

    # In the roster, but holds NO member-cap over the session (revoked / never granted).
    assert {:error, :unauthorized} =
             Membership.authorize(chat_slice(owner, member), member, session, member)
  end

  test "current member (HOLDS the member-cap) is ALLOWED (test 22)" do
    owner = confirmed_user("owner")
    member = confirmed_user("member")
    session = session_uri()

    grant_member_cap(member, session, owner)

    assert :ok = Membership.authorize(chat_slice(owner, member), member, session, member)
  end

  test "a member holding only a member-cap over a DIFFERENT session is DENIED" do
    owner = confirmed_user("owner")
    member = confirmed_user("member")
    session = session_uri()
    other = session_uri()

    grant_member_cap(member, other, owner)

    assert {:error, :unauthorized} =
             Membership.authorize(chat_slice(owner, member), member, session, member)
  end

  test "the owner authorizes only through the same member-cap gate" do
    owner = confirmed_user("owner")
    session = session_uri()
    grant_member_cap(owner, session, owner)

    assert :ok =
             Membership.authorize(%{owner_uri: owner, members: %{}}, owner, session, owner)
  end

  test "an explicit nil session context fails closed" do
    owner = confirmed_user("owner")
    member = confirmed_user("member")

    assert {:error, :unauthorized} =
             Membership.authorize(chat_slice(owner, member), member, nil, member)
  end

  test "a bumped session generation invalidates a dormant member read cap" do
    owner = confirmed_user("owner")
    member = confirmed_user("member")
    session = session_uri()

    grant_member_cap(member, session, owner)

    assert :ok = Membership.authorize(chat_slice(owner, member), member, session, member)

    assert {:ok, _new_authority} =
             Ezagent.Cap.Authority.regenesis(
               session,
               :session
             )

    assert {:error, :unauthorized} =
             Membership.authorize(chat_slice(owner, member), member, session, member)
  end
end
