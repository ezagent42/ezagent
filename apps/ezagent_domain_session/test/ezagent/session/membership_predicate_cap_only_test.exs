defmodule Ezagent.Session.MembershipPredicateCapOnlyTest do
  @moduledoc "M-1: membership and owner access are both proven by a current tier-1 member cap."

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, IdentityCaps}
  alias Ezagent.Session.Membership

  test "a current cap-holder absent from the roster is authorized" do
    owner = confirmed_user("owner")
    holder = confirmed_user("holder")
    session = session_uri()
    grant_cap(holder, member_cap(session))

    assert holder not in Map.keys(chat(owner, %{}).members)
    assert :ok = Membership.authorize(chat(owner, %{}), holder, session, holder)
  end

  test "a stale roster entry without the member cap is denied" do
    owner = confirmed_user("owner")
    ex_member = confirmed_user("ex-member")
    session = session_uri()

    assert {:error, :unauthorized} =
             Membership.authorize(
               chat(owner, %{ex_member => %{online: true}}),
               ex_member,
               session,
               ex_member
             )
  end

  test "owner URI equality is not an authorization bypass" do
    owner = confirmed_user("owner-without-cap")
    session = session_uri()

    assert IdentityCaps.load(owner) != []

    assert {:error, :unauthorized} =
             Membership.authorize(chat(owner, %{}), owner, session, owner)
  end

  test "an owner with the born-signed member cap authorizes through the same gate" do
    owner = confirmed_user("owner-with-cap")
    session = session_uri()
    grant_cap(owner, member_cap(session))

    assert :ok = Membership.authorize(chat(owner, %{}), owner, session, owner)
  end

  test "the create-time owner grant is synchronous and immediately authorizes" do
    owner = confirmed_user("created-owner")
    session = session_uri()

    assert {:ok, pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
               uri: session,
               owner_uri: owner,
               behaviors: Ezagent.Entity.Session.behaviors()
             })

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          pid
        )
      end
    end)

    assert :ok =
             Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(session, owner)

    assert :ok = Membership.authorize(chat(owner, %{}), owner, session, owner)
  end

  test "read_unfiltered without tier-1 membership remains only a row-policy modifier" do
    owner = confirmed_user("owner")
    supervisor = confirmed_user("supervisor")
    session = session_uri()
    grant_cap(supervisor, read_unfiltered_cap(session))

    assert {:error, :unauthorized} =
             Membership.authorize(chat(owner, %{}), supervisor, session, supervisor)
  end

  defp confirmed_user(prefix) do
    uri = Ezagent.URI.user("membership-cap-only", "#{prefix}-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(uri, "pw-#{unique()}", [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp grant_cap(holder, cap) do
    assert :ok =
             Ezagent.Identity.Grant.grant_cap_via_router(
               holder,
               cap,
               {:admin, Ezagent.Entity.User.admin_uri()},
               :sync
             )
  end

  defp member_cap(session) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :receive,
      session,
      Capability.workspace_of(session)
    )
  end

  defp read_unfiltered_cap(session) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :read_unfiltered,
      session,
      Capability.workspace_of(session)
    )
  end

  defp chat(owner, members), do: %{owner_uri: owner, members: members}

  defp session_uri do
    Ezagent.URI.session("membership-cap-only", :default, "session-#{unique()}")
  end

  defp unique, do: System.unique_integer([:positive])
end
