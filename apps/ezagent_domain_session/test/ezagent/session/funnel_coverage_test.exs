defmodule Ezagent.Session.FunnelCoverageTest do
  @moduledoc "M-7: every sibling add path converges on grant intent plus holder self-add."

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.ActionSet.Session

  test "T15: merge grants and self-adds to, leaves from, and repoints read markers" do
    {session, session_pid} = spawn_session()
    {from, from_pid} = confirmed_user("from")
    {to, to_pid} = confirmed_user("to")

    :ok = grant_member_cap(from, session)
    :ok = cast_add_self(session, from)
    assert wait_member(session, from)
    assert holds_member_cap?(from, session)

    marker = "merge-marker-#{unique()}"
    assert {:ok, :updated} = Ezagent.Session.ReadMarker.mark(session, from, marker, :read)

    target = Ezagent.URI.with_action(session, :session, :merge_member)

    assert {:ok, %{status: :granted, member: ^to}} =
             Invocation.dispatch(%Invocation{
               origin: :authenticated_external,
               target: target,
               mode: :call,
               args: %{from: from, to: to},
               ctx: %{
                 caller: to,
                 authenticated_principal: to,
                 caps: MapSet.new([signed_action_cap!(target, to)]),
                 reply: :ignore
               }
             })

    assert wait_member(session, to)
    refute wait_member(session, from, 5)
    assert holds_member_cap?(to, session)
    refute holds_member_cap?(from, session)
    assert Ezagent.Session.ReadMarker.last_read(session, to, :read) == marker
    assert Ezagent.Session.ReadMarker.last_read(session, from, :read) == nil

    terminate_if_live(session_pid, EzagentDomainInstanceMessage.SessionSupervisor)
    terminate_if_live(from_pid, EzagentDomainIdentity.Application.UserSupervisor)
    terminate_if_live(to_pid, EzagentDomainIdentity.Application.UserSupervisor)
  end

  defp spawn_session do
    session = Ezagent.URI.session("m7-funnel", :default, "s-#{unique()}")

    assert {:ok, pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
               uri: session,
               owner_uri: Ezagent.Entity.User.admin_uri(),
               behaviors: Ezagent.Entity.Session.behaviors()
             })

    :ok = Ezagent.WorkspaceRegistry.bind(session, Capability.workspace_of(session))

    on_exit(fn ->
      Ezagent.WorkspaceRegistry.unbind(session)
      terminate_if_live(pid, EzagentDomainInstanceMessage.SessionSupervisor)
    end)

    {session, pid}
  end

  defp confirmed_user(prefix) do
    member = Ezagent.URI.user("m7-funnel", "#{prefix}-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(member, "pw-#{unique()}", [])
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(member)

    on_exit(fn -> terminate_if_live(pid, EzagentDomainIdentity.Application.UserSupervisor) end)
    {member, pid}
  end

  defp member_cap(session) do
    Capability.cap(
      :session,
      Session,
      :receive,
      session,
      Capability.workspace_of(session)
    )
  end

  defp grant_member_cap(member, session) do
    Ezagent.Identity.Grant.grant_cap_via_router(
      member,
      member_cap(session),
      {:admin, Ezagent.Entity.User.admin_uri()},
      :sync
    )
  end

  defp cast_add_self(session, member) do
    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(session, :session, :add_self),
      mode: :cast,
      args: %{member: member, facets: %{}},
      ctx: %{
        caller: member,
        authenticated_principal: member,
        caps: MapSet.new(),
        reply: :ignore
      }
    })
  end

  defp holds_member_cap?(member, session) do
    member
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?(&(Capability.identity_key(&1) == Capability.identity_key(member_cap(session))))
  end

  defp wait_member(session, member, retries \\ 100) do
    cond do
      Map.has_key?(members_of(session), member) ->
        true

      retries > 0 ->
        Process.sleep(10)
        wait_member(session, member, retries - 1)

      true ->
        false
    end
  end

  defp members_of(session) do
    case Ezagent.Kind.read(session, :session, spawn: :never) do
      {:ok, %{state: %{members: members}}} -> members
      {:ok, %{members: members}} -> members
      _ -> %{}
    end
  end

  defp terminate_if_live(pid, supervisor) do
    if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)
  end

  defp unique, do: System.unique_integer([:positive])
end
