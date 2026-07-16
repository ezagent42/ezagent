defmodule Ezagent.ActionSet.Session.PendingNotifyTest do
  @moduledoc """
  Membership-cap unification Part C.3 (spec §C.3 / R4) — the cascade-SUBJECT
  discriminator. A pending cross-owner admission request notifies
  `managers_of(the pending MEMBER) = A` (the member's owner), content-free — it
  must NOT notify `managers_of(the SESSION) = B`. This is the one non-obvious
  wiring point: the generic `{entity,:caps}` cascade would resolve
  `managers_of(SESSION) = B`, the exact WRONG target.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
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

    :ok = Ezagent.Identity.TargetAuthority.ensure(granter, target)
    :ok = Ezagent.Identity.Grant.grant_cap(granter, cap, {:held_by, granter})
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

  test "pending cross-owner add notifies the MEMBER's managers (A), NOT the session's (B) (test 29)" do
    ws = new_ws()
    b = confirmed_user(ws, "owner-b")
    b_session = new_session("adm-notify", b)
    a = confirmed_user(ws, "owner-a")
    a_agent = agent_member(ws, "a-agent")
    grant_manage(a, a_agent)

    # A is the pending member's manager; B is the session's owner (manager).
    assert Ezagent.Identity.Cascade.managers_of(a_agent) == [a],
           "precondition: managers_of(a_agent) = A"

    # Subscribe AFTER setup so only the pending-add notification is observed.
    :ok = Ezagent.Notifications.subscribe(a)
    :ok = Ezagent.Notifications.subscribe(b)

    _ = dispatch_join(b_session, a_agent, b)

    # A (managers_of the MEMBER) is notified with the content-free approvable
    # request envelope.
    assert_receive {:notification, ^a, %{type: :pending_admission} = notif}, 2_000

    # B (managers_of the SESSION) is NOT notified — the cascade-subject discriminator.
    refute_receive {:notification, ^b, _}, 300

    # Content-free: {member, session, request_ref} only — no message body, no caps.
    assert Enum.sort(Map.keys(notif.body)) == [:member, :request_ref, :session]
    assert notif.body.member == URI.to_string(a_agent)
    assert notif.body.session == URI.to_string(b_session)
    assert is_binary(notif.body.request_ref)
  end
end
