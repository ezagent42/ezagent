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

  setup do
    cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)
    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, cap_config) end)
    :ok
  end

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

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  # Drive the REAL `session.join` dispatch (the member-cap grant now lives INSIDE
  # `do_join`, so it fires on dispatch). Authorized with the admin genesis
  # wildcard so the test never has to replay the per-surface provision dance —
  # the member-cap granter is the session OWNER (read off the session slice),
  # independent of the dispatch caller.
  defp dispatch_join(session_uri, member_uri, extra_args \\ %{}) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    admin = Ezagent.Entity.User.admin_uri()
    {:ok, cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: Map.put(extra_args, :member, member_uri),
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
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
      member_cap(entity_uri, session_uri) ->
        member_cap(entity_uri, session_uri)

      retries > 0 ->
        Process.sleep(10)
        wait_member_cap(entity_uri, session_uri, retries - 1)

      true ->
        nil
    end
  end

  # A BROAD action-wildcard cap over the session (`action: :any`). Under
  # `Capability.matches?/2` it satisfies the concrete `:receive` need — the HIGH:
  # an at-join idempotency keyed on `matches?/2` would treat a broad-cap member as
  # "already authorized" and SKIP the concrete member-cap grant. Its
  # `identity_key/1` differs from the concrete member-cap, so exact-identity
  # idempotency must still grant the concrete cap.
  defp broad_session_cap(session_uri) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :any,
      session_uri,
      Capability.workspace_of(session_uri)
    )
  end

  # Grant a wildcard-action cap (needs ADMIN authority — the rule tag is rejected
  # by the wildcard-grant gate), under the `{:genesis, admin}` authority — the
  # admin-genesis provenance the HIGH is about.
  defp grant_broad_cap(member_uri, cap) do
    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        member_uri,
        cap,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )
  end

  # The member's PERSISTED identity caps as the at-join idempotency reads them
  # (`Membership.member_snapshot_caps/1` semantics: `SnapshotStore.latest`).
  defp snapshot_identity_caps(member_uri) do
    case Ezagent.SnapshotStore.latest(member_uri) do
      {:ok, %{state: state}} when is_map(state) ->
        state
        |> Map.get(:identity, %{})
        |> Ezagent.Kind.normalize_slice_view()
        |> Map.get(:caps)
        |> case do
          caps when is_list(caps) -> caps
          %MapSet{} = caps -> MapSet.to_list(caps)
          other -> List.wrap(other)
        end

      _ ->
        []
    end
  end

  # Poll until the member's SNAPSHOT (the idempotency source) contains `cap` —
  # so the at-join idempotency read genuinely SEES the broad cap. Without this
  # the test would be vacuous (a lagging snapshot reads `[]`, the buggy
  # matches?-idempotency would then ALSO grant the concrete cap).
  defp wait_snapshot_has(member_uri, cap, retries \\ 200) do
    target = Capability.identity_key(cap)

    present? =
      snapshot_identity_caps(member_uri)
      |> Enum.any?(fn
        %Capability{} = c -> Capability.identity_key(c) == target
        _ -> false
      end)

    cond do
      present? ->
        :ok

      retries > 0 ->
        Process.sleep(10)
        wait_snapshot_has(member_uri, cap, retries - 1)

      true ->
        flunk("broad cap never appeared in #{URI.to_string(member_uri)} snapshot")
    end
  end

  test "join grants the member-cap into the member's identity caps (granted_by = owner) [test 1]" do
    owner = confirmed_user("owner")
    session = new_session("mc-user", owner)
    member = confirmed_user("member")

    _ = dispatch_join(session, member)

    cap = wait_member_cap(member, session)
    assert cap, "a joined user must hold the member-cap over the session"

    assert cap.granted_by == owner,
           "member-cap must be issued by the session owner through target K.grant"
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

  test "a member already holding a BROAD :any cap STILL gets the concrete member-cap at join [HIGH refutation]" do
    owner = confirmed_user("owner")
    session = new_session("mc-broad", owner)
    member = confirmed_user("member")

    # Pre-existing broad cap: `matches?/2` would consider the member "already
    # authorized" for :receive → the buggy at-join idempotency SKIPS the grant.
    grant_broad_cap(member, broad_session_cap(session))

    # Make the test non-vacuous: ensure the broad cap is actually in the SNAPSHOT
    # the at-join idempotency reads, so the skip-path is genuinely exercised.
    wait_snapshot_has(member, broad_session_cap(session))

    refute member_cap(member, session),
           "precondition: member holds only the broad cap, not the concrete member-cap"

    _ = dispatch_join(session, member)

    assert wait_member_cap(member, session),
           "a broad-:any-cap member must STILL receive the concrete " <>
             "cap(:session, Session, :receive, S) — exact-identity idempotency, not matches?/2 (HIGH)"
  end

  test "an invalid-signature persisted artifact does not suppress the required join grant" do
    owner = confirmed_user("owner-invalid-signature")
    session = new_session("mc-invalid-signature", owner)
    member = URI.new!("entity://system/user/member-invalid-signature-#{uniq()}")
    valid = issued_member_cap(owner, member, session)
    invalid = %{valid | signature: :binary.copy(<<0>>, byte_size(valid.signature))}

    assert Capability.identity_key(invalid) == Capability.identity_key(valid),
           "the regression requires a stale artifact with the exact required identity"

    assert {:ok, _row} = Ezagent.Users.create(member, "pw-not-secret-#{uniq()}", [invalid])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(member)

    _ = dispatch_join(session, member)

    assert wait_member_cap(member, session),
           "a bad signature must be treated as grant not observed"
  end

  test "a valid artifact bound to another receiver does not suppress the required join grant" do
    owner = confirmed_user("owner-wrong-receiver")
    session = new_session("mc-wrong-receiver", owner)
    member = URI.new!("entity://system/user/member-wrong-receiver-#{uniq()}")
    other = URI.new!("entity://system/user/other-wrong-receiver-#{uniq()}")
    wrong_receiver = issued_member_cap(owner, other, session)

    assert {:ok, _row} =
             Ezagent.Users.create(member, "pw-not-secret-#{uniq()}", [wrong_receiver])

    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(member)

    _ = dispatch_join(session, member)

    assert wait_member_cap(member, session),
           "another receiver's artifact must be treated as grant not observed"
  end

  test "join role-conflict preflight → NO orphaned member-cap [test 23 subset]" do
    owner = confirmed_user("owner")
    session = new_session("mc-conflict", owner)

    role = "dup-role-#{uniq()}"
    first = confirmed_user("first")
    second = confirmed_user("second")

    # First member claims the role_name.
    _ = dispatch_join(session, first, %{role_name: role})

    assert wait_member_cap(first, session)

    # Second member's join CONFLICTS on the same role_name → rejected BEFORE the
    # grant (the preflight is a zero-side-effect check placed before the grant).
    result = dispatch_join(session, second, %{role_name: role})

    assert match?({:error, _}, result), "a role_name-conflicting join must be rejected"

    Process.sleep(50)

    refute member_cap(second, session),
           "a role-conflict rejection must NOT orphan a member-cap (grant is AFTER the preflight)"
  end

  defp issued_member_cap(_owner, receiver, session) do
    requested =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session,
        Capability.workspace_of(session)
      )

    {:ok, cap} =
      Ezagent.Cap.issue({:admin, Ezagent.Entity.User.admin_uri()}, receiver, requested)

    cap
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
