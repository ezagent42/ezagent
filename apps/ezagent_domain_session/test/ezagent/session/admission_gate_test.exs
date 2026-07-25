defmodule Ezagent.ActionSet.Session.AdmissionGateTest do
  @moduledoc """
  Membership-cap unification Part C.1 (spec §C.1 / R4) — the admission TRIGGER at
  the common `handle_join/2` chokepoint. A CROSS-OWNER add (a real, non-system
  caller who does NOT manage the member and is not the member itself) records a
  PENDING request on the `:pending_members` slice and grants NO member-cap / does
  NOT mount into `:members`. Every over-fire exemption (owner-adds-own / admin /
  materializer-admin-caller / self-join / anon self-admission) MOUNTS unchanged.

  Tests drive the REAL `session.join` dispatch. `ctx.caps` carries the admin
  genesis wildcard ONLY to clear the join-cap CapBAC gate — the admission decision
  reads the CALLER's DURABLE identity caps by URI (`Authority.manages?/2`), NOT
  `ctx.caps`, so a genesis `ctx.caps` never suppresses the gate.

  Entities live in a UNIQUE NON-system workspace per test: the `system` workspace
  is the admin workspace, so a `entity://system/user/…` caller would be a
  workspace-admin (`manages?` true) and never pend. A plain team workspace makes
  the cross-owner caller a genuine non-manager.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Identity.Authority
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2]

  defp uniq, do: System.unique_integer([:positive])

  defp new_ws, do: "admws-#{uniq()}"

  # Workspace derives structurally from the owner's URI (owner is
  # `entity://<ws>/user/…`), so the session lands in the owner's workspace.
  defp new_session(_ws, prefix, owner) do
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

  defp unconfirmed_user(ws, prefix) do
    uri = URI.new!("entity://#{ws}/user/anon-#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create_read_only(uri)
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

  # Grant `granter` durable manage-authority over `target` (the `CreatorGrant`
  # shape), so `Authority.manages?(granter, target)` becomes true.
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

  # Drive the REAL `session.join` dispatch as `caller` (genesis ctx.caps only to
  # clear the join-cap gate — the admission decision ignores ctx.caps).
  defp dispatch_join(session_uri, member_uri, caller) do
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

  defp session_state(session_uri) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
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

  # ---- PENDING (cross-owner) ---------------------------------------------

  test "cross-owner add goes PENDING, grants NO member-cap, NOT mounted (test 28)" do
    ws = new_ws()
    b = confirmed_user(ws, "owner-b")
    b_session = new_session(ws, "adm-cross", b)
    a_agent = agent_member(ws, "a-agent")

    # B (the session owner) does NOT manage A's agent.
    refute Authority.manages?(b, a_agent), "precondition: B must not manage A's agent"

    _ = dispatch_join(b_session, a_agent, b)

    # Deterministic anchor: the pending record commits synchronously with the
    # call-mode dispatch — proves the no-grant/no-mount branch ran.
    assert Map.has_key?(read_pending(b_session), a_agent),
           "a cross-owner add must record a pending admission request"

    refute Map.has_key?(read_members(b_session), a_agent),
           "a pending member must NOT be mounted into :members"

    refute member_cap(a_agent, b_session),
           "a pending member must hold NO member-cap (R1.1 ⇒ cannot receive ⇒ cred not spent)"

    entry = Map.get(read_pending(b_session), a_agent)
    assert entry.requested_by == b, "pending entry records the requester (B)"
    assert is_binary(entry.request_ref), "pending entry carries an opaque request_ref"
  end

  # ---- OVER-FIRE EXEMPTIONS (must MOUNT, not pend) -----------------------

  test "owner adds its OWN agent → MOUNTS, no pending (over-fire guard, test 27)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session = new_session(ws, "adm-own", owner)
    agent = agent_member(ws, "own-agent")
    grant_manage(owner, agent)

    assert Authority.manages?(owner, agent), "precondition: owner manages its own agent"

    _ = dispatch_join(session, agent, owner)

    assert wait_member_cap(agent, session),
           "an owner-managed add must mount (hold the member-cap)"

    refute Map.has_key?(read_pending(session), agent), "a manage-authorized add must NOT pend"
  end

  test "materializer / admin-caller add → MOUNTS, no pending (over-fire guard, test 27)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session = new_session(ws, "adm-admin", owner)
    member = agent_member(ws, "mat-agent")

    # The materializer dispatches under admin_uri with only a narrow inline join
    # cap; its exemption rests ENTIRELY on manages?(admin, member) resolving the
    # admin's DURABLE genesis wildcard (admin union) — NOT ctx.caps. Pin it.
    assert Authority.manages?(Ezagent.Entity.User.admin_uri(), member),
           "precondition: manages?(admin_uri, member) must be TRUE (genesis wildcard, admin union) " <>
             "— else every team-template spawn stalls at PENDING"

    _ = dispatch_join(session, member, Ezagent.Entity.User.admin_uri())

    assert wait_member_cap(member, session), "a materializer/admin add must mount"
    refute Map.has_key?(read_pending(session), member), "a materializer/admin add must NOT pend"
  end

  test "self-join (caller == member) → MOUNTS, no pending (over-fire guard)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session = new_session(ws, "adm-self", owner)
    member = confirmed_user(ws, "self")

    _ = dispatch_join(session, member, member)

    assert wait_member_cap(member, session), "a self-join must mount"
    refute Map.has_key?(read_pending(session), member), "a self-join must NOT pend"
  end

  test "caller holding a {:spawned_by, caller} cap over a worker IT spawned → MOUNTS (orchestrator spawn-authority, over-fire guard)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session = new_session(ws, "adm-spawn", owner)
    controller = confirmed_user(ws, "controller")
    member = agent_member(ws, "spawned")

    # Record the worker's lineage as spawned-by the controller, and give the
    # controller the delegated `{:spawned_by, controller}` agent-`:any` cap the
    # orchestrator holds (`session_manager.ex:375`). `manages?` is false (not a
    # Manage cap), so the mount is via the `{:spawned_by, caller}` exemption ONLY.
    :ok = Ezagent.AgentLineage.record(member, controller)

    spawned_by_cap =
      Capability.cap(
        :agent,
        Ezagent.ActionSet.Sandbox,
        :destroy,
        member,
        Capability.workspace_of(member)
      )

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        controller,
        spawned_by_cap,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )

    refute Authority.manages?(controller, member),
           "precondition: a {:spawned_by} :any cap is NOT a Manage cap → manages? false"

    _ = dispatch_join(session, member, controller)

    assert wait_member_cap(member, session),
           "a caller holding {:spawned_by, caller} over the worker it spawned must mount"

    refute Map.has_key?(read_pending(session), member), "a spawned-by-caller add must NOT pend"
  end

  # 🔴 TEETH TEST (spec §C.1 / threat X) — the `{:spawned_by, caller}` exemption must
  # NOT broaden to "any cap covering the member." A co-tenant B in the SAME workspace
  # as A's agent, holding a broad `{:within_workspace, ws}` agent cap (which COVERS
  # A's agent), is STILL a cross-owner puller — it must PEND. If the exemption were a
  # general covering-cap check, this would mount and reopen threat X.
  test "co-tenant with an exact target cap but no spawn lineage does NOT exempt → still PENDS (teeth)" do
    ws = new_ws()
    b = confirmed_user(ws, "cotenant-b")
    b_session = new_session(ws, "adm-teeth", b)
    a_agent = agent_member(ws, "a-agent")

    exact_cap =
      Capability.cap(
        :agent,
        Ezagent.ActionSet.Sandbox,
        :destroy,
        a_agent,
        Capability.workspace_of(a_agent)
      )

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        b,
        exact_cap,
        {:admin, Ezagent.Entity.User.admin_uri()},
        :sync
      )

    refute Authority.manages?(b, a_agent),
           "precondition: an exact non-Manage cap is not Manage/admin authority"

    _ = dispatch_join(b_session, a_agent, b)

    assert Map.has_key?(read_pending(b_session), a_agent),
           "an exact cap without caller lineage must still PEND (threat X closed)"

    refute member_cap(a_agent, b_session), "no member-cap granted to a pended co-tenant add"
    refute Map.has_key?(read_members(b_session), a_agent), "not mounted"
  end

  test "anon self-admission (caller == member) → MOUNTS, no pending (over-fire guard)" do
    ws = new_ws()
    owner = confirmed_user(ws, "owner")
    session = new_session(ws, "adm-anon", owner)
    anon = unconfirmed_user(ws, "viewer")

    _ = dispatch_join(session, anon, anon)

    assert wait_member_cap(anon, session), "anon self-admission must mount"
    refute Map.has_key?(read_pending(session), anon), "anon self-admission must NOT pend"
  end
end
