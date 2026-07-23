defmodule Ezagent.Session.CreationReadinessTest do
  @moduledoc "M-4: durable monotonic join cursor closes the grant-to-mount message window."

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Message, MessageStore, SnapshotStore}
  alias Ezagent.ActionSet.Session
  alias Ezagent.ActionSet.Session.SelfAdd.Effects
  alias Ezagent.Ecto.KindSnapshot

  test "a message written after grant intent is replayed when the member projection converges" do
    {session, _session_pid} = spawn_session()
    {member, member_pid} = confirmed_user("readiness")
    :ok = grant_member_cap(member, session)
    assert wait_mounted(session, member)

    assert {:ok, first} =
             Message.new(member, %{text: "first", attachments: []})
             |> MessageStore.write(session)

    {_members, effects} =
      Effects.on_add(
        member,
        member_pid,
        %{},
        handler_ctx(session, member, 0),
        Session
      )

    assert {:set, :members, %{^member => %{joined_cursor: 0}}} =
             Enum.find(effects, &match?({:set, :members, _}, &1))

    assert wait_received(member, first.id),
           "the first post-grant message must be replayed from the durable join cursor"
  end

  test "member activation heals a durable cursor after a crash before self-add" do
    {session, session_pid} = spawn_session()
    {member, member_pid} = confirmed_user("crash-recovery")

    assert {:ok, _} = dispatch_join(session, member)
    assert wait_join_cursor(session, member) == 0
    assert wait_member_cap(member, session)

    assert :ok =
             DynamicSupervisor.terminate_child(
               EzagentDomainInstanceMessage.SessionSupervisor,
               session_pid
             )

    assert :ok =
             DynamicSupervisor.terminate_child(
               EzagentDomainIdentity.Application.UserSupervisor,
               member_pid
             )

    persist_pre_self_add_snapshot(session, member)

    assert {:ok, missed} =
             Message.new(member, %{text: "between-grant-and-mount", attachments: []})
             |> MessageStore.write(session)

    assert {:ok, _new_session_pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
               uri: session,
               owner_uri: Ezagent.Entity.User.admin_uri(),
               behaviors: Ezagent.Entity.Session.behaviors()
             })

    assert {:ok, _new_member_pid} = Ezagent.SpawnRegistry.spawn(member)

    assert wait_mounted(session, member)
    assert wait_received(member, missed.id)
  end

  defp spawn_session do
    session = Ezagent.URI.session("creation-readiness", :default, "s-#{unique()}")

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
    uri = Ezagent.URI.user("creation-readiness", "#{prefix}-#{unique()}")
    assert {:ok, _row} = Ezagent.Users.create(uri, "pw-#{unique()}", [])
    assert {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)

    on_exit(fn ->
      terminate_if_live(pid, EzagentDomainIdentity.Application.UserSupervisor)
    end)

    {uri, pid}
  end

  defp grant_member_cap(member, session) do
    cap =
      Capability.cap(
        :session,
        Session,
        :receive,
        session,
        Capability.workspace_of(session)
      )

    Ezagent.Identity.Grant.grant_cap_via_router(
      member,
      cap,
      {:admin, Ezagent.Entity.User.admin_uri()},
      :sync
    )
  end

  defp dispatch_join(session, member) do
    admin = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.with_action(session, :session, :join)
    {:ok, cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{member: member},
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
        reply: :ignore
      },
      origin: :trusted_internal
    })
  end

  defp persist_pre_self_add_snapshot(session, member) do
    row = KindSnapshot.get(URI.to_string(session))
    assert {:ok, state} = KindSnapshot.decode_state(row)

    session_slice = Map.fetch!(state, :session)

    session_slice =
      case session_slice do
        %{state: durable} = lifecycle ->
          %{lifecycle | state: Map.put(durable, :members, %{})}

        durable when is_map(durable) ->
          Map.put(durable, :members, %{})
      end

    state = Map.put(state, :session, session_slice)
    assert {:ok, _} = SnapshotStore.write(session, state, kind_type: :session, version: 0)

    assert snapshot_join_cursor(state, member) == 0
  end

  defp snapshot_join_cursor(state, member) do
    case Map.fetch!(state, :session) do
      %{state: durable} -> get_in(durable, [:join_cursors, member])
      durable -> get_in(durable, [:join_cursors, member])
    end
  end

  defp wait_join_cursor(session, member, retries \\ 100) do
    case session_state(session) |> get_in([:join_cursors, member]) do
      nil when retries > 0 ->
        Process.sleep(10)
        wait_join_cursor(session, member, retries - 1)

      cursor ->
        cursor
    end
  end

  defp wait_member_cap(member, session, retries \\ 100) do
    held? =
      member
      |> Ezagent.Identity.list_caps_for()
      |> Enum.any?(fn cap ->
        cap.kind == :session and Capability.action_of(cap) == :receive and
          Ezagent.URI.stable_key(cap.instance) == Ezagent.URI.stable_key(session)
      end)

    cond do
      held? ->
        true

      retries > 0 ->
        Process.sleep(10)
        wait_member_cap(member, session, retries - 1)

      true ->
        false
    end
  end

  defp wait_mounted(session, member, retries \\ 100) do
    cond do
      Map.has_key?(Map.get(session_state(session), :members, %{}), member) ->
        true

      retries > 0 ->
        Process.sleep(10)
        wait_mounted(session, member, retries - 1)

      true ->
        false
    end
  end

  defp session_state(session) do
    case Ezagent.Kind.get_slice(session, :session) do
      {:ok, slice} -> Ezagent.Kind.normalize_slice_view(slice)
      _ -> %{}
    end
  end

  defp handler_ctx(session, member, cursor) do
    %{
      self_uri: session,
      caller: member,
      authenticated_principal: member,
      transients: %{monitors: %{}},
      read: fn
        :members, _default -> %{}
        :join_cursors, _default -> %{member => cursor}
        :last_seen, _default -> %{}
        :owner_uri, _default -> Ezagent.Entity.User.admin_uri()
        _key, default -> default
      end
    }
  end

  defp wait_received(member, message_id, retries \\ 100) do
    case Ezagent.Kind.get_slice(member, :session) do
      {:ok, slice} ->
        slice = Ezagent.Kind.normalize_slice_view(slice)

        if Enum.any?(Map.get(slice, :recent_messages, []), fn {_cursor, id} ->
             id == message_id
           end) do
          true
        else
          retry_received(member, message_id, retries)
        end

      _ ->
        retry_received(member, message_id, retries)
    end
  end

  defp retry_received(_member, _message_id, 0), do: false

  defp retry_received(member, message_id, retries) do
    Process.sleep(10)
    wait_received(member, message_id, retries - 1)
  end

  defp terminate_if_live(pid, supervisor) do
    if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)
  end

  defp unique, do: System.unique_integer([:positive])
end
