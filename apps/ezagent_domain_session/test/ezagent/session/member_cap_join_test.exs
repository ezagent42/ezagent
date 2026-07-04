defmodule Ezagent.ActionSet.Session.MemberCapJoinTest do
  @moduledoc """
  Membership-cap unification A1.2 (spec tests 1, 2, 3 + the A1 subset of test 23)
  — at JOIN, EVERY member (user, agent, anon) is granted the universal member-cap
  `cap(:session, Session, :receive, S)` into its OWN `:identity` slice, `granted_by`
  the session OWNER (ownerless → the #154 admin granter).

  This is the ADDITIVE foundation (A1): the grant lands, but delivery/receive are
  UNCHANGED (still the ephemeral mint) — so these tests assert only the member-cap's
  PRESENCE/ABSENCE, never a receive/delivery behavior (that is A2).

  The grant is placed inside `do_join` (spec R1.3/R2.1 JOIN sequence: preflight →
  grant → `do_join_apply` → compensate), so it fires for ALL member kinds through
  the ONE `handle_join` chokepoint. Tests drive the REAL `session.join` dispatch.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.ActionSet.Session.Membership

  defp uniq, do: System.unique_integer([:positive])

  defp new_session(prefix, owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "#{prefix}-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp unconfirmed_user(prefix) do
    uri = URI.new!("entity://system/user/anon-#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create_read_only(uri)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp agent_member(prefix) do
    uri = Ezagent.URI.entity(:system, :agent, "#{prefix}-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  # Drive the REAL `session.join` dispatch (the member-cap grant now lives INSIDE
  # `do_join`, so it fires on dispatch). Authorized with the admin genesis
  # wildcard so the test never has to replay the per-surface provision dance —
  # the member-cap granter is the session OWNER (read off the session slice),
  # independent of the dispatch caller.
  defp dispatch_join(session_uri, member_uri) do
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: :ignore
      }
    })
  end

  defp member_cap_over?(%Capability{} = cap, session_uri) do
    cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
      Capability.action_of(cap) == :receive and cap.instance == session_uri
  end

  defp member_cap_over?(_, _), do: false

  defp send_cap_over?(%Capability{} = cap, session_uri) do
    cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
      Capability.action_of(cap) == :send and cap.instance == session_uri
  end

  defp send_cap_over?(_, _), do: false

  defp member_cap(entity_uri, session_uri) do
    entity_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.find(&member_cap_over?(&1, session_uri))
  end

  defp wait_member_cap(entity_uri, session_uri, retries \\ 100) do
    cond do
      member_cap(entity_uri, session_uri) -> member_cap(entity_uri, session_uri)
      retries > 0 -> Process.sleep(10); wait_member_cap(entity_uri, session_uri, retries - 1)
      true -> nil
    end
  end

  test "join grants the member-cap into the member's identity caps (granted_by = owner) [test 1]" do
    owner = confirmed_user("owner")
    session = new_session("mc-user", owner)
    member = confirmed_user("member")

    _ = dispatch_join(session, member)

    cap = wait_member_cap(member, session)
    assert cap, "a joined user must hold the member-cap over the session"
    assert cap.granted_by == owner, "member-cap granted_by must be the session owner"
  end

  test "join grants the member-cap to an AGENT member (agents carry :identity caps) [test 2]" do
    owner = confirmed_user("owner")
    session = new_session("mc-agent", owner)
    agent = agent_member("agent")

    _ = dispatch_join(session, agent)

    assert wait_member_cap(agent, session),
           "a joined agent must hold the member-cap (R1.4 — agents carry :identity caps)"
  end

  test "anon join grants the member-cap but NOT Session.:send (unconfirmed tier) [test 3]" do
    owner = confirmed_user("owner")
    session = new_session("mc-anon", owner)
    anon = unconfirmed_user("viewer")

    _ = dispatch_join(session, anon)

    assert wait_member_cap(anon, session), "an anon member must hold the member-cap"

    refute Enum.any?(Ezagent.Identity.list_caps_for(anon), &send_cap_over?(&1, session)),
           "anon (unconfirmed) must NOT get :send from the member-cap grant (that is the mount tier)"
  end

  test "join role-conflict preflight → NO orphaned member-cap [test 23 subset]" do
    owner = confirmed_user("owner")
    session = new_session("mc-conflict", owner)

    role = "dup-role-#{uniq()}"
    first = confirmed_user("first")
    second = confirmed_user("second")

    # First member claims the role_name.
    _ =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: URI.new!("#{URI.to_string(session)}?action=session.join"),
        mode: :call,
        args: %{member: first, role_name: role},
        ctx: %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: MapSet.new([Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    assert wait_member_cap(first, session)

    # Second member's join CONFLICTS on the same role_name → rejected BEFORE the
    # grant (the preflight is a zero-side-effect check placed before the grant).
    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: URI.new!("#{URI.to_string(session)}?action=session.join"),
        mode: :call,
        args: %{member: second, role_name: role},
        ctx: %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: MapSet.new([Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    assert match?({:error, _}, result), "a role_name-conflicting join must be rejected"

    Process.sleep(50)

    refute member_cap(second, session),
           "a role-conflict rejection must NOT orphan a member-cap (grant is AFTER the preflight)"
  end

  test "join failure AFTER grant → compensating revoke leaves no member-cap [test 23 subset]" do
    owner = confirmed_user("owner")
    session = new_session("mc-compensate", owner)
    member = confirmed_user("member")
    {:ok, member_pid} = Ezagent.KindRegistry.lookup(member)

    refute member_cap(member, session), "precondition: member holds no member-cap yet"

    # Inject a failure INSIDE `do_join_apply` (raises when it reads `:last_seen`,
    # which is read only AFTER the member-cap grant) by calling `do_join`
    # directly with a `ctx.read` that raises on that key. The grant lands, then
    # `do_join_apply` fails → compensation must revoke the just-granted cap.
    ctx = %{
      self_uri: session,
      caller: member,
      transients: %{monitors: %{}},
      read: fn
        :last_seen, _default -> raise "injected do_join_apply failure"
        :owner_uri, _default -> owner
        _key, default -> default
      end
    }

    assert_raise RuntimeError, fn ->
      Membership.do_join(member, member_pid, ctx, %{}, Ezagent.ActionSet.Session)
    end

    Process.sleep(50)

    refute member_cap(member, session),
           "a post-grant do_join_apply failure must compensate — the member-cap must be revoked"
  end
end
