defmodule Ezagent.Session.HeldCapReceiveTest do
  @moduledoc """
  Membership-cap unification A2.2 (spec tests 7, 8, 20, 21) — the receive
  cutover: `:receive` is cap-EXEMPT and BOTH receive sites authorize in-handler on
  the recipient's HELD member-cap (read from the pre-loaded `:identity` sibling),
  the ephemeral `member_receive_caps/1` bearer mint is DELETED, and delivery
  presents NO receive cap.

  The behavioral cases invoke the real `handle_receive/2` clauses through the
  `BehaviorInvoker` with the exact ctx the runtime injects (`caller` = the source
  session, `siblings[:identity]` = the recipient's own caps), so they prove the
  WIRING (site → `MemberReceive.authorize/1`), not just the predicate.
  """

  # F-6 fixture normalization starts a real recipient Kind so the held caps
  # can be target-signed against its current generation. Own that database
  # work explicitly and run serially; bare async ExUnit processes have no
  # sandbox checkout and fail nondeterministically in the umbrella suite.
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Message}
  alias Ezagent.ActionSet.User.Receive, as: UserReceive
  alias Ezagent.ActionSet.Agent.Receive, as: AgentReceive
  alias EzagentDomainInstanceMessage.Test.BehaviorInvoker, as: Invoker

  # __DIR__ = apps/ezagent_domain_session/test/ezagent/session
  @session_app_root Path.expand("../../..", __DIR__)
  @apps_root Path.expand("../../../..", __DIR__)

  defp uniq, do: System.unique_integer([:positive])

  defp session_uri, do: URI.new!("session://system/default/sess-#{uniq()}")

  # The universal member-cap `cap(:session, Session, :receive, S)`, granted_by a
  # real entity (the owner) — the shape the at-join grant mints.
  defp member_cap(session_uri) do
    %Capability{
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session_uri,
        Capability.workspace_of(session_uri)
      )
      | granted_by: URI.new!("entity://system/user/owner-#{uniq()}"),
        granted_at: DateTime.utc_now()
    }
  end

  # The receive ctx as the runtime injects it: `caller` = source session,
  # `siblings[:identity]` = the recipient's OWN pre-loaded identity slice.
  defp receive_ctx(recipient, session, held_caps) do
    %{
      self_uri: recipient,
      caller: session,
      slice_change_cursor: 1,
      siblings: %{identity: %{caps: MapSet.new(held_caps)}}
    }
  end

  defp msg(session) do
    Message.new(URI.new!("#{URI.to_string(session)}"), %{text: "hi", attachments: []})
  end

  # ── test 7: the ephemeral mint is deleted, delivery presents no member-cap ──

  test "member_receive_caps/1 has no definition and no caller (grep-gate, test 7)" do
    delivery =
      File.read!(Path.join(@session_app_root, "lib/ezagent/behavior/session/delivery.ex"))

    refute delivery =~ "member_receive_caps(",
           "the ephemeral member_receive_caps/1 bearer mint (def + all callers) must be deleted (R1.1)"

    assert delivery =~ "caps: MapSet.new()",
           "delivery must present NO receive cap (empty ctx.caps) on the fan-out"
  end

  # ── the single-:receive-dispatch-site guard invariant (R1.2) ──

  test "the ONLY :receive dispatch site is the session fan-out (guard invariant)" do
    dispatch_sites =
      Path.wildcard(Path.join(@apps_root, "*/lib/**/*.ex"))
      |> Enum.filter(fn path ->
        body = File.read!(path)

        body =~ "action: :receive" and
          Regex.match?(~r/Router\.dispatch|Invocation\.dispatch|%Cmd\{|%Ezagent\.Cmd\{/, body)
      end)
      |> Enum.map(&Path.basename/1)
      |> Enum.uniq()

    assert dispatch_sites == ["delivery.ex"],
           "the sole :receive dispatch must remain Delivery.dispatch_receive_call/3 " <>
             "(MemberReceive.authorize/1 assumes ctx.caller is the source session); " <>
             "found: #{inspect(dispatch_sites)}"
  end

  # ── test 7/20: held cap authorizes; test 8: non-member denied (User) ──

  test "User.Receive: a member holding the member-cap is authorized → slice written (test 7/20)" do
    session = session_uri()
    user = URI.new!("entity://system/user/recv-#{uniq()}")
    m = msg(session)

    ctx = receive_ctx(user, session, [member_cap(session)])

    assert {:ok, new_slice} = Invoker.invoke(UserReceive, :receive, %{}, %{message: m}, ctx)
    assert new_slice.last_received.message_id == m.id
  end

  test "User.Receive: a non-member (no member-cap, stale roster) is DENIED (test 8/21)" do
    session = session_uri()
    stranger = URI.new!("entity://system/user/stranger-#{uniq()}")
    m = msg(session)

    # Roster may still list this recipient (delivery attempted it), but it holds
    # NO member-cap over `session` — the in-handler check denies.
    ctx = receive_ctx(stranger, session, [])

    assert {:error, :unauthorized} =
             Invoker.invoke(UserReceive, :receive, %{}, %{message: m}, ctx)
  end

  test "User.Receive: a member whose cap was REVOKED is DENIED immediately, no reconcile (test 20/21)" do
    session = session_uri()
    user = URI.new!("entity://system/user/exmember-#{uniq()}")
    m = msg(session)

    # Post-revoke the recipient's identity slice holds no member-cap. Delivery is
    # unchanged (roster left stale on purpose); the very next receive is denied by
    # the held-cap read alone — no session re-activation / reconcile.
    ctx = receive_ctx(user, session, [])

    assert {:error, :unauthorized} =
             Invoker.invoke(UserReceive, :receive, %{}, %{message: m}, ctx)
  end

  # ── Agent site is gated identically, BEFORE the bridge short-circuit (R2.3) ──

  test "Agent.Receive: a non-member agent is DENIED before the bridge short-circuit (test 8)" do
    session = session_uri()
    agent = URI.new!("entity://system/agent/np-#{uniq()}")
    m = msg(session)

    ctx = receive_ctx(agent, session, [])

    # Denied at the top of handle_receive/2 — deliver_agent_receive is never
    # reached (no bridge side effect on a non-member).
    assert {:error, :unauthorized} =
             Invoker.invoke(AgentReceive, :receive, %{}, %{message: m}, ctx)
  end
end
