defmodule Ezagent.Session.JoinGrantOnlyTest do
  @moduledoc "M-5: join records a grant intent; only add_self writes the roster."

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session

  test "handle_join emits no roster, monitor, replay, or membership-broadcast effects" do
    {session, _session_pid} = spawn_session()
    {member, _member_pid} = confirmed_user("effects")

    assert {:ok, _result, effects} =
             Session.handle_join(
               %{member: member, role_name: "reviewer"},
               handler_ctx(session)
             )

    refute Enum.any?(effects, fn
             {:set, key, _} when key in [:members, :last_seen] -> true
             {:set_transient, :monitors, _} -> true
             {:notify, _, {:member_joined, _}} -> true
             _ -> false
           end)
  end

  test "join can mint for an offline principal without structurally mounting it" do
    {session, _session_pid} = spawn_session()
    member = Ezagent.URI.user("join-grant-only", "offline-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(member, "pw-#{unique()}", [])
    refute match?({:ok, _}, Ezagent.KindRegistry.lookup(member))

    assert {:ok, _result, effects} =
             Session.handle_join(%{member: member}, handler_ctx(session))

    refute Enum.any?(effects, &match?({:set, :members, _}, &1))
  end

  test "T2: a Phase-A grant failure cannot produce a roster member" do
    failed_target =
      URI.new!("entity://join-grant-only/missing_kind/grant-failure-#{unique()}")

    member = confirmed_user_uri("grant-failure-member")

    assert {:error, {:member_cap_grant_failed, _reason}} =
             Session.handle_join(%{member: member}, handler_ctx(failed_target))

    refute member_cap_over?(member, failed_target)
  end

  test "first non-anonymous user claims an ownerless session on the intent commit" do
    {session, _session_pid} = spawn_session()
    {member, _member_pid} = confirmed_user("owner-claim")

    assert {:ok, _result, effects} =
             Session.handle_join(%{member: member}, handler_ctx(session, owner_uri: nil))

    assert Enum.any?(effects, &match?({:set, :owner_uri, ^member}, &1))
    refute Enum.any?(effects, &match?({:set, :members, _}, &1))
  end

  test "SessionCreator still completes without the historical self-call deadlock" do
    {owner, _owner_pid} = confirmed_user("creator-owner")

    assert {:ok, session, _meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "grant-only-#{unique()}",
               owner,
               template_name: "default"
             )

    assert %URI{} = session
  end

  defp spawn_session do
    session = Ezagent.URI.session("join-grant-only", :default, "s-#{unique()}")

    assert {:ok, pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
               uri: session,
               owner_uri: Ezagent.Entity.User.admin_uri(),
               behaviors: Ezagent.Entity.Session.behaviors()
             })

    :ok = Ezagent.WorkspaceRegistry.bind(session, Ezagent.Capability.workspace_of(session))

    on_exit(fn ->
      Ezagent.WorkspaceRegistry.unbind(session)
      terminate_if_live(pid, EzagentDomainInstanceMessage.SessionSupervisor)
    end)

    {session, pid}
  end

  defp confirmed_user(prefix) do
    uri = confirmed_user_uri(prefix)
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)

    on_exit(fn ->
      terminate_if_live(pid, EzagentDomainIdentity.Application.UserSupervisor)
    end)

    {uri, pid}
  end

  defp confirmed_user_uri(prefix) do
    uri = Ezagent.URI.user("join-grant-only", "#{prefix}-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(uri, "pw-#{unique()}", [])
    uri
  end

  defp handler_ctx(session, opts \\ []) do
    owner_uri = Keyword.get(opts, :owner_uri, Ezagent.Entity.User.admin_uri())

    %{
      self_uri: session,
      caller: Ezagent.Entity.User.admin_uri(),
      authenticated_principal: Ezagent.Entity.User.admin_uri(),
      transients: %{monitors: %{}},
      read: fn
        :members, _default -> %{}
        :join_cursors, _default -> %{}
        :join_facets, _default -> %{}
        :pending_members, _default -> %{}
        :last_seen, _default -> %{}
        :owner_uri, _default -> owner_uri
        _key, default -> default
      end
    }
  end

  defp member_cap_over?(member, session) do
    member
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?(fn cap ->
      cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
        Ezagent.Capability.action_of(cap) == :receive and cap.instance == session
    end)
  end

  defp terminate_if_live(pid, supervisor) do
    if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)
  end

  defp unique, do: System.unique_integer([:positive])
end
