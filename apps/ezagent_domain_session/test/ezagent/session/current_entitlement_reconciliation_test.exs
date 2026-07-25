defmodule Ezagent.Session.CurrentEntitlementReconciliationTest do
  @moduledoc "M-10: roster is not entitlement; rejoin requires a fresh tier-0 grant."

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Socialware.MemberBackfill

  test "stale roster cannot remount tier-2 after the current tier-1 cap is revoked" do
    owner = confirmed_user("owner-roster")
    member = confirmed_user("member-roster")
    session = session(owner, "roster")

    assert :ok = grant_and_join(session, member, owner)
    assert wait_cap?(member, member_cap(session))

    assert :ok = MemberBackfill.backfill(session, member)
    assert wait_cap?(member, send_cap(session))

    assert :ok = revoke(member, member_cap(session))
    assert :ok = revoke(member, send_cap(session))
    refute cap?(member, member_cap(session))
    refute cap?(member, send_cap(session))
    assert roster_has?(session, member), "precondition: the stale projection still lists M"

    assert :ok = MemberBackfill.backfill(session, member)
    Process.sleep(100)

    refute cap?(member, member_cap(session)), "backfill must never mint tier-1"
    refute cap?(member, send_cap(session)), "tier-2 requires a current tier-1 entitlement"
  end

  test "a consumed join grant cannot re-arm revoked membership; a fresh grant can" do
    owner = confirmed_user("owner-rejoin")
    member = confirmed_user("member-rejoin")
    session = session(owner, "rejoin")

    assert :ok = grant_and_join(session, member, owner)
    assert wait_cap?(member, member_cap(session))
    assert wait_cap?(member, join_cap(session), false), "a successful join consumes tier-0"

    assert :ok = revoke(member, member_cap(session))
    refute cap?(member, member_cap(session))

    assert {:error, _reason} = dispatch_self_join(session, member)
    refute cap?(member, member_cap(session)), "navigation without a new grant must stay dropped"

    assert :ok = Membership.provision_invited_join_authority(session, member, owner)
    assert wait_cap?(member, join_cap(session))

    assert {:ok, %{status: status, member: ^member}} = dispatch_self_join(session, member)
    assert status in [:granted, :already_member]
    assert wait_cap?(member, member_cap(session))
    assert wait_cap?(member, join_cap(session), false), "the replacement grant is single-use too"
  end

  defp grant_and_join(session, member, owner) do
    with :ok <- Membership.provision_invited_join_authority(session, member, owner),
         {:ok, %{status: :granted, member: ^member}} <- dispatch_self_join(session, member) do
      :ok
    end
  end

  defp dispatch_self_join(session, member) do
    Invocation.dispatch(%Invocation{
      origin: :authenticated_external,
      target: Ezagent.URI.with_action(session, :session, :join),
      mode: :call,
      args: %{member: member},
      ctx: %{
        caller: member,
        authenticated_principal: member,
        caps: Ezagent.Identity.list_caps_for(member),
        reply: :ignore
      }
    })
  end

  defp revoke(member, cap) do
    Ezagent.Identity.Grant.revoke_cap_via_router(
      member,
      cap,
      {:admin, Ezagent.Entity.User.admin_uri()},
      :sync
    )
  end

  defp roster_has?(session, member) do
    case Ezagent.Kind.read(session, :session, spawn: :never) do
      {:ok, slice} ->
        slice
        |> Ezagent.Kind.normalize_slice_view()
        |> Map.get(:members, %{})
        |> Map.has_key?(member)

      _ ->
        false
    end
  end

  defp cap?(holder, wanted) do
    wanted_key = Capability.identity_key(wanted)

    Enum.any?(Ezagent.Identity.list_caps_for(holder), fn
      %Capability{} = held -> Capability.identity_key(held) == wanted_key
      _ -> false
    end)
  end

  defp wait_cap?(holder, wanted, expected \\ true, retries \\ 150)

  defp wait_cap?(holder, wanted, expected, retries) do
    present? = cap?(holder, wanted)

    cond do
      present? == expected -> true
      retries > 0 -> Process.sleep(10) && wait_cap?(holder, wanted, expected, retries - 1)
      true -> false
    end
  end

  defp member_cap(session),
    do: cap(Ezagent.ActionSet.Session, :receive, session)

  defp join_cap(session),
    do: cap(Ezagent.ActionSet.Session, :join, session)

  defp send_cap(session),
    do: cap(Ezagent.ActionSet.Session, :send, session)

  defp cap(behavior, action, session) do
    Capability.cap(
      :session,
      behavior,
      action,
      session,
      Capability.workspace_of(session)
    )
  end

  defp confirmed_user(prefix) do
    uri = Ezagent.URI.user(:system, "#{prefix}-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(uri, "pw-#{unique()}", [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp session(owner, prefix) do
    assert {:ok, session, _meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "m10-#{prefix}-#{unique()}",
               owner,
               template_name: "default",
               workspace: "system"
             )

    session
  end

  defp unique, do: System.unique_integer([:positive])
end
