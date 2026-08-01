defmodule Ezagent.Identity.MembershipConvergenceTest do
  @moduledoc "M-3: identity-owned, cap-land and activate driven roster convergence."

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability

  test "granting a tier-1 member cap eventually self-mounts the holder" do
    {session, _session_pid} = spawn_session()
    {member, _member_pid} = confirmed_user("fast-path")

    refute Map.has_key?(members_of(session), member)
    assert :ok = grant_member_cap(member, session)

    assert wait_member(session, member)
  end

  test "activate planning stops dispatching once the holder is mounted" do
    {session, _session_pid} = spawn_session()
    {member, _member_pid} = confirmed_user("idempotent")
    assert :ok = grant_member_cap(member, session)
    assert wait_member(session, member)

    handler_id = "membership-convergence-#{unique()}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:ezagent, :identity, :membership_convergence, :dispatch],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:convergence_dispatch, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    state = %{caps: MapSet.new(Ezagent.IdentityCaps.load(member))}

    result = Ezagent.ActionSet.Identity.activate(state, %{self_uri: member})

    assert match?({:ok, %{}}, result) or match?({:ok, %{}, _state}, result)

    refute_receive {:convergence_dispatch, %{session_uri: ^session}}, 100
  end

  test "an offline projection remains pending so activation can reconnect it" do
    {session, _session_pid} = spawn_session()
    {member, member_pid} = confirmed_user("offline")
    assert :ok = grant_member_cap(member, session)
    assert wait_member_online(session, member, true)

    assert :ok =
             DynamicSupervisor.terminate_child(
               EzagentDomainIdentity.Application.UserSupervisor,
               member_pid
             )

    assert wait_member_online(session, member, false)

    held_caps = Ezagent.IdentityCaps.load(member)

    assert [
             {:dispatch_after_commit, %Ezagent.Cmd{action: :add_self, args: %{member: ^member}}}
           ] = Ezagent.Identity.MembershipConvergence.after_commit_effects(member, held_caps)
  end

  test "convergence has no session-domain module pin and Identity is shared by user and agent workers" do
    path =
      Path.expand(
        "../../../lib/ezagent/identity/membership_convergence.ex",
        __DIR__
      )

    source = File.read!(path)
    refute source =~ "Ezagent.ActionSet.Session"
    assert source =~ "action=session.add_self"

    identity_source =
      "../../../lib/ezagent/behavior/identity.ex"
      |> Path.expand(__DIR__)
      |> File.read!()

    assert identity_source =~ "MembershipConvergence.converge("
    assert identity_source =~ "membership_convergence_effects(receiver, [cap])"

    assert Ezagent.ActionSet.Identity in Ezagent.Entity.User.behaviors()
    assert Ezagent.ActionSet.Identity in Ezagent.Entity.Agent.behaviors()
  end

  defp spawn_session do
    session = Ezagent.URI.session("membership-convergence", :default, "s-#{unique()}")

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
    uri = Ezagent.URI.user("membership-convergence", "#{prefix}-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(uri, "pw-#{unique()}", [])
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)

    on_exit(fn -> terminate_if_live(pid, EzagentDomainIdentity.Application.UserSupervisor) end)
    {uri, pid}
  end

  defp grant_member_cap(member, session) do
    Ezagent.Identity.Grant.grant_cap_via_router(
      member,
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session,
        Capability.workspace_of(session)
      ),
      {:admin, Ezagent.Entity.User.admin_uri()},
      :sync
    )
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

  defp wait_member_online(session, member, online?, retries \\ 100) do
    case Map.get(members_of(session), member) do
      %{online: ^online?} ->
        true

      _ when retries > 0 ->
        Process.sleep(10)
        wait_member_online(session, member, online?, retries - 1)

      _ ->
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
