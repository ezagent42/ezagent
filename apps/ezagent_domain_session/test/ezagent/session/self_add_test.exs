defmodule Ezagent.Session.SelfAddTest do
  @moduledoc "M-2: cap-exempt dispatch with a durable, holder-bound tier-1 gate in-handler."

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.ActionSet.Session

  test "forged ctx.caps cannot self-add without a durably held member cap" do
    {session, _session_pid} = spawn_session()
    {attacker, _attacker_pid} = confirmed_user("attacker")
    forged = member_cap(session)
    ctx = handler_ctx(session, attacker, MapSet.new([forged]))

    assert {:error, :unauthorized} =
             Session.handle_add_self(%{member: attacker, facets: %{}}, ctx)

    assert :ok = cast_add_self(session, attacker, MapSet.new([forged]))
    refute wait_member(session, attacker, 10)
  end

  test "the authenticated holder may add only itself" do
    {session, _session_pid} = spawn_session()
    {holder, _holder_pid} = confirmed_user("holder")
    {other, _other_pid} = confirmed_user("other")
    :ok = grant_member_cap(holder, session)

    assert {:error, :unauthorized} =
             Session.handle_add_self(
               %{member: other, facets: %{}},
               handler_ctx(session, holder, MapSet.new())
             )
  end

  test "a durable member-cap holder is mounted exactly once" do
    {session, _session_pid} = spawn_session()
    {member, _member_pid} = confirmed_user("member")
    :ok = grant_member_cap(member, session)

    assert :ok = cast_add_self(session, member)
    assert wait_member(session, member)
    assert :ok = cast_add_self(session, member)
    assert wait_member(session, member)

    assert [^member] = Map.keys(members_of(session))
  end

  test "add_self is exempt in both lists and cast-only" do
    assert :add_self in Session.cap_exempt_actions()
    assert Ezagent.Cap.Verifier.non_cap_action?(Session, :add_self)
    assert Ezagent.ActionSet.action_spec(Session, :add_self).modes == [:cast]
  end

  defp spawn_session do
    session = Ezagent.URI.session("self-add", :default, "s-#{unique()}")

    assert {:ok, pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
               uri: session,
               owner_uri: Ezagent.Entity.User.admin_uri(),
               behaviors: Ezagent.Entity.Session.behaviors()
             })

    on_exit(fn -> terminate_if_live(pid, EzagentDomainInstanceMessage.SessionSupervisor) end)
    {session, pid}
  end

  defp confirmed_user(prefix) do
    uri = Ezagent.URI.user("self-add", "#{prefix}-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(uri, "pw-#{unique()}", [])
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)

    on_exit(fn -> terminate_if_live(pid, EzagentDomainIdentity.Application.UserSupervisor) end)
    {uri, pid}
  end

  defp grant_member_cap(member, session) do
    Ezagent.Identity.Grant.grant_cap_via_router(
      member,
      member_cap(session),
      {:admin, Ezagent.Entity.User.admin_uri()},
      :sync
    )
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

  defp cast_add_self(session, member, caps \\ MapSet.new()) do
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.with_action(session, :session, :add_self),
      mode: :cast,
      args: %{member: member, facets: %{}},
      ctx: %{
        caller: member,
        authenticated_principal: member,
        caps: caps,
        reply: :ignore
      },
      origin: :trusted_internal
    })
  end

  defp handler_ctx(session, holder, caps) do
    %{
      self_uri: session,
      caller: holder,
      authenticated_principal: holder,
      caps: caps,
      transients: %{monitors: %{}},
      read: fn
        :members, _default -> %{}
        :last_seen, _default -> %{}
        :owner_uri, _default -> Ezagent.Entity.User.admin_uri()
        _key, default -> default
      end
    }
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
    case Ezagent.Kind.get_slice(session, :session) do
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
