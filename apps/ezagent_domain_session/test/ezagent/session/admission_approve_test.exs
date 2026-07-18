defmodule Ezagent.ActionSet.Session.AdmissionApproveTest do
  @moduledoc """
  Membership-cap unification Part C.2 (spec §C.4/§C.5 / R4) — the approve / deny /
  withdraw admission actions.

    * APPROVE (a manager of the member) re-enters the exact grant+mount join tail
      C.1 withheld (member-cap granted + mounted into :members), then drops the
      pending entry. A non-manager approve is rejected with zero mutation.
    * DENY (a manager) drops the pending entry — no cap was ever granted.
    * WITHDRAW (the requester) drops its own pending entry.

  The actions are CAP-EXEMPT (the member's owner A holds no session cap on B's
  session): the approve-by-A dispatch carries EMPTY ctx.caps and still reaches the
  handler, proving authority is the in-handler `manages?`/`requested_by` predicate,
  not a session-scoped CapBAC cap.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Identity.Authority
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  defp uniq, do: System.unique_integer([:positive])
  defp new_ws, do: "admws-#{uniq()}"

  defp new_session(prefix, owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "#{prefix}-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  defp confirmed_user(ws, prefix) do
    uri = URI.new!("entity://#{ws}/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp agent_member(ws, prefix) do
    uri = URI.new!("entity://#{ws}/agent/#{prefix}-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  defp grant_manage(granter, target) do
    cap =
      Ezagent.CreatorGrant.manage_cap(:agent, target, Capability.workspace_of(target), granter)

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        granter,
        cap,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )
  end

  defp dispatch_join(session_uri, member_uri, caller) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: caller,
        caps: MapSet.new([signed_action_cap!(target, caller)]),
        reply: :ignore
      }
    })
  end

  # Dispatch a cap-exempt admission action with the given caller + caps (default
  # EMPTY caps — the actions are cap-exempt, authorized in-handler).
  defp dispatch_admission(session_uri, action, member_uri, caller, caps \\ MapSet.new([])) do
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: URI.new!("#{URI.to_string(session_uri)}?action=session.#{action}"),
      mode: :call,
      args: %{member: member_uri},
      ctx: %{caller: caller, caps: caps, reply: :ignore}
    })
  end

  defp session_state(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{state: state}} when is_map(state) -> state
      {:ok, state} when is_map(state) -> state
      _ -> %{}
    end
  end

  defp read_pending(session_uri), do: session_state(session_uri) |> Map.get(:pending_members, %{})
  defp read_members(session_uri), do: session_state(session_uri) |> Map.get(:members, %{})

  defp member_cap_over?(%Capability{} = cap, session_uri) do
    cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
      Capability.action_of(cap) == :receive and cap.instance == session_uri
  end

  defp member_cap_over?(_, _), do: false

  defp member_cap(entity_uri, session_uri) do
    entity_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.find(&member_cap_over?(&1, session_uri))
  end

  defp wait_member_cap(entity_uri, session_uri, retries \\ 100) do
    cond do
      member_cap(entity_uri, session_uri) ->
        member_cap(entity_uri, session_uri)

      retries > 0 ->
        Process.sleep(10)
        wait_member_cap(entity_uri, session_uri, retries - 1)

      true ->
        nil
    end
  end

  # A pending cross-owner add: B (owner) adds A's agent (B does not manage it),
  # A holds manage-authority over its agent (so A may approve).
  defp pending_cross_owner_add do
    ws = new_ws()
    b = confirmed_user(ws, "owner-b")
    b_session = new_session("adm-appr", b)
    a = confirmed_user(ws, "owner-a")
    a_agent = agent_member(ws, "a-agent")
    grant_manage(a, a_agent)

    _ = dispatch_join(b_session, a_agent, b)
    assert Map.has_key?(read_pending(b_session), a_agent), "precondition: request is pending"
    assert Authority.manages?(a, a_agent), "precondition: A manages A's agent"
    refute Authority.manages?(b, a_agent), "precondition: B does NOT manage A's agent"

    %{ws: ws, b_session: b_session, b: b, a: a, a_agent: a_agent}
  end

  test "owner (manages member) approves → member mounts + holds cap, pending dropped (test 31)" do
    %{b_session: b_session, a: a, a_agent: a_agent} = pending_cross_owner_add()

    # A holds NO session cap on B's session → dispatch with EMPTY caps; the
    # cap-exempt action reaches the handler and manages?(A, agent) authorizes.
    assert {:ok, _} = dispatch_admission(b_session, :approve_admission, a_agent, a)

    assert wait_member_cap(a_agent, b_session),
           "approve must grant the member-cap (now a functional member — R1.1 authorizes receive)"

    assert Map.has_key?(read_members(b_session), a_agent), "approve must mount into :members"
    refute Map.has_key?(read_pending(b_session), a_agent), "approve must drop the pending entry"
  end

  test "non-manager approve is rejected, zero mutation (test 31)" do
    %{b_session: b_session, b: b, a_agent: a_agent} = pending_cross_owner_add()

    assert {:error, _} = dispatch_admission(b_session, :approve_admission, a_agent, b)

    assert Map.has_key?(read_pending(b_session), a_agent), "pending entry untouched"
    refute member_cap(a_agent, b_session), "no member-cap granted by a rejected approve"
    refute Map.has_key?(read_members(b_session), a_agent), "not mounted"
  end

  test "deny (by a manager) drops pending, no cap ever granted (test 32)" do
    %{b_session: b_session, a: a, a_agent: a_agent} = pending_cross_owner_add()

    assert {:ok, _} = dispatch_admission(b_session, :deny_admission, a_agent, a)

    refute Map.has_key?(read_pending(b_session), a_agent), "deny drops the pending entry"
    refute member_cap(a_agent, b_session), "deny never grants a cap"
    refute Map.has_key?(read_members(b_session), a_agent), "deny never mounts"
  end

  test "deny by a NON-manager is rejected, pending untouched (test 32)" do
    %{b_session: b_session, b: b, a_agent: a_agent} = pending_cross_owner_add()

    assert {:error, _} = dispatch_admission(b_session, :deny_admission, a_agent, b)
    assert Map.has_key?(read_pending(b_session), a_agent), "a non-manager deny leaves the entry"
  end

  test "withdraw by the requester (B) drops pending (test 32)" do
    %{b_session: b_session, b: b, a_agent: a_agent} = pending_cross_owner_add()

    assert {:ok, _} = dispatch_admission(b_session, :withdraw_admission, a_agent, b)
    refute Map.has_key?(read_pending(b_session), a_agent), "requester withdraw drops the entry"
    refute member_cap(a_agent, b_session), "withdraw never grants a cap"
  end

  test "withdraw by a NON-requester is rejected, pending untouched (test 32)" do
    %{b_session: b_session, a: a, a_agent: a_agent} = pending_cross_owner_add()

    # A manages the agent but is NOT the requester (B is) → withdraw denied.
    assert {:error, _} = dispatch_admission(b_session, :withdraw_admission, a_agent, a)

    assert Map.has_key?(read_pending(b_session), a_agent),
           "a non-requester withdraw leaves the entry"
  end
end
