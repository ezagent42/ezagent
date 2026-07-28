defmodule Ezagent.ActionSet.Session.MemberCapRemovalTest do
  @moduledoc """
  Membership-cap unification A2.4 (spec R3.1 — leave/remove revoke the member-cap)
  — spec tests 10, 11 + the R3.1 abort-safe revoke property, driven through the
  REAL `session.remove_participant` dispatch (the in-Kind inline-sync revoke).

    * LEAVE / owner-REMOVE: the member-cap is revoked AND the roster entry dropped.
    * a REJECTED removal (authz gate) leaves BOTH the member-cap AND the roster
      intact — the revoke is placed AFTER every rejecting check, so it never runs
      on a rejected removal (spec test 11's invariant, via the authz gate).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2, signed_required_cap!: 5]
  alias Ezagent.Session.Participants

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

  defp dispatch_join(session_uri, member_uri) do
    caller = Ezagent.Entity.User.admin_uri()
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: MapSet.new([signed_action_cap!(target, caller)]),
        reply: :ignore
      }
    })
  end

  defp member_cap_over?(%Capability{} = cap, session_uri) do
    cap.kind == :session and Capability.action_of(cap) == :receive and cap.instance == session_uri
  end

  defp member_cap_over?(_, _), do: false

  defp holds_member_cap?(entity_uri, session_uri) do
    entity_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?(&member_cap_over?(&1, session_uri))
  end

  # A1 grants the member-cap :async at join; poll until it lands before we test
  # revocation (the grant-path reliability is A1's; A2.4 tests the REVOKE).
  defp wait_member_cap(entity_uri, session_uri, retries \\ 200) do
    cond do
      holds_member_cap?(entity_uri, session_uri) ->
        :ok

      retries > 0 ->
        Process.sleep(10)
        wait_member_cap(entity_uri, session_uri, retries - 1)

      true ->
        flunk("member-cap never landed for #{URI.to_string(entity_uri)}")
    end
  end

  # The roster (`:members`) is written by the holder-driven `add_self` action,
  # NOT by `do_join` ("`add_self` is the sole roster writer" — Session.Membership).
  # `add_self` is triggered by the member-cap ABSORB, so it lands STRICTLY AFTER
  # the cap: `wait_member_cap/3` returning does not imply the roster is written.
  # Poll the derived projection too, so the removal tests start from a fully
  # settled membership instead of racing the add_self cast. Bounded — if the
  # roster genuinely never converges (a real regression), this flunks rather than
  # masking it.
  defp wait_member_in_roster(session_uri, member_uri, retries \\ 200) do
    cond do
      Map.has_key?(read_members(session_uri), member_uri) ->
        :ok

      retries > 0 ->
        Process.sleep(10)
        wait_member_in_roster(session_uri, member_uri, retries - 1)

      true ->
        flunk("member never landed in the roster for #{URI.to_string(member_uri)}")
    end
  end

  defp read_members(session_uri) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, %{state: %{members: m}}} when is_map(m) -> m
      {:ok, %{members: m}} when is_map(m) -> m
      _ -> %{}
    end
  end

  # Operator ctx: caller + an inline :remove_participant cap so the dispatch clears
  # the chokepoint; the handler's owner/self/admin gate is the real authorization.
  defp op_ctx(%URI{} = caller, %URI{} = session_uri) do
    cap =
      signed_required_cap!(
        session_uri,
        :session,
        Ezagent.ActionSet.Session,
        :remove_participant,
        caller
      )

    %{caller: caller, authenticated_principal: caller, caps: MapSet.new([cap])}
  end

  defp joined_member(session_uri, prefix) do
    member = confirmed_user(prefix)
    _ = dispatch_join(session_uri, member)
    :ok = wait_member_cap(member, session_uri)
    :ok = wait_member_in_roster(session_uri, member)
    member
  end

  test "owner-remove REVOKES the member-cap AND drops the roster (test 10)" do
    owner = confirmed_user("owner")
    session = new_session("rm", owner)
    member = joined_member(session, "member")

    assert Map.has_key?(read_members(session), member)

    assert {:ok, %{status: :removed}} =
             Participants.remove_participant(session, member, op_ctx(owner, session))

    refute holds_member_cap?(member, session), "member-cap must be revoked on remove"
    refute Map.has_key?(read_members(session), member), "roster entry must be dropped"
  end

  test "self-leave (caller == member) REVOKES the member-cap AND drops the roster (test 10)" do
    owner = confirmed_user("owner")
    session = new_session("leave", owner)
    member = joined_member(session, "member")

    assert {:ok, %{status: :removed}} =
             Participants.remove_participant(session, member, op_ctx(member, session))

    refute holds_member_cap?(member, session), "member-cap must be revoked on self-leave"
    refute Map.has_key?(read_members(session), member)
  end

  test "a REJECTED (unauthorized) removal leaves BOTH the member-cap AND the roster intact (test 11 shape)" do
    owner = confirmed_user("owner")
    session = new_session("denied", owner)
    member = joined_member(session, "member")
    stranger = confirmed_user("stranger")

    # The stranger clears the dispatch chokepoint (inline cap) but the handler's
    # owner/self/admin gate REJECTS — before do_remove_participant, so the revoke
    # (placed after every rejecting check, R3.1) never runs.
    assert {:error, :unauthorized} =
             Participants.remove_participant(session, member, op_ctx(stranger, session))

    assert holds_member_cap?(member, session),
           "a rejected removal must leave the member-cap intact"

    assert Map.has_key?(read_members(session), member),
           "a rejected removal must leave the roster intact"
  end
end
