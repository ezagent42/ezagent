defmodule Ezagent.Acceptance.MemberCapCascadeAcceptanceTest do
  @moduledoc """
  Membership-cap unification §14.5(A) acceptance — Phase A2's DONE-GATE.

  A2 lands ONLY the **defense-in-depth** assertion (step 5): a revoked member
  cannot receive IMMEDIATELY, proven WITHOUT reconcile. It is set up via a
  MANAGE-AUTHORIZED mount (the owner mounts its OWN agent), which mounts
  immediately under both pre-C and post-C (a cross-owner add would go PENDING
  under Phase C and never mount, breaking a naive setup).

  The receive is driven through the real delivery primitive
  (`Delivery.dispatch_receive_call/3`) so the assertion isolates the HELD-CAP
  authority (R1.1) from the roster: after remove, the agent holds no member-cap,
  so its `:receive` is denied at the in-handler `MemberReceive.authorize/1`
  check — with the session process NEVER re-activated (no reconcile).

  §14.5(A) PRIMARY prevention (steps 1-4, Phase C) and the cascade (step 6,
  Phase B) are `@tag :skip`-ed with pointers.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Message}
  alias Ezagent.ActionSet.Session.Delivery
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

  # The owner's OWN agent — a real Agent Kind carrying an :identity slice, bound
  # to the session's workspace. (Manage-authority is a Phase C concern; in A2 the
  # mount is a normal join under the admin-genesis dispatch.)
  defp owned_agent(session_uri, prefix) do
    ws = Capability.workspace_of(session_uri)
    uri = Ezagent.URI.entity(:system, :agent, "#{prefix}-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, ws)
    uri
  end

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

  defp holds_member_cap?(entity_uri, session_uri) do
    entity_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?(fn
      %Capability{kind: :session} = cap ->
        Capability.action_of(cap) == :receive and cap.instance == session_uri

      _ ->
        false
    end)
  end

  defp wait_member_cap(entity_uri, session_uri, retries \\ 200) do
    cond do
      holds_member_cap?(entity_uri, session_uri) -> :ok
      retries > 0 -> Process.sleep(10); wait_member_cap(entity_uri, session_uri, retries - 1)
      true -> flunk("member-cap never landed for #{URI.to_string(entity_uri)}")
    end
  end

  defp op_ctx(%URI{} = caller, %URI{} = session_uri) do
    cap = %Capability{
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :remove_participant,
        session_uri,
        Capability.workspace_of(session_uri)
      )
      | granted_by: caller,
        granted_at: DateTime.utc_now()
    }

    %{caller: caller, caps: MapSet.new([cap])}
  end

  test "§14.5(A) step 5 [defense-in-depth]: revoke ⇒ immediate deny, no reconcile" do
    owner = confirmed_user("owner")
    session = new_session("dind", owner)
    agent = owned_agent(session, "cc-agent")

    # Bind a test bridge channel so an AUTHORIZED agent.receive surfaces as an
    # observable push; an UNAUTHORIZED receive produces none.
    :ok = Ezagent.AgentBridge.Registry.bind(agent, self())
    :ok = Ezagent.AgentFlavorAttributes.put(agent, "cc")

    on_exit(fn ->
      Ezagent.AgentBridge.Registry.unbind(agent)
      Ezagent.AgentFlavorAttributes.delete(agent)
    end)

    # Manage-authorized mount (owner mounts its OWN agent) → holds the member-cap.
    _ = dispatch_join(session, agent)
    :ok = wait_member_cap(agent, session)

    {:ok, session_pid_before} = Ezagent.KindRegistry.lookup(session)

    # The mounted member RECEIVES (holds the member-cap; in-handler authz passes).
    Delivery.dispatch_receive_call(agent, Message.new(owner, %{text: "hello", attachments: []}), session)
    assert_receive {:agent_bridge_push, "to_claude", %{"content" => "hello"}}, 1_000

    # 🔴 defense-in-depth: remove ⇒ revoke the member-cap ⇒ the very next receive
    # is DENIED (no held cap), with NO session re-activation / reconcile.
    assert {:ok, %{status: :removed}} =
             Participants.remove_participant(session, agent, op_ctx(owner, session))

    refute holds_member_cap?(agent, session), "remove must have revoked the member-cap"

    Delivery.dispatch_receive_call(agent, Message.new(owner, %{text: "again", attachments: []}), session)

    refute_receive {:agent_bridge_push, "to_claude", %{"content" => "again"}}, 500

    # ...proven WITHOUT reconcile: the session process was never re-activated
    # (reconcile_after_load/2 runs only in activate/2 on a fresh/restarted Kind).
    {:ok, session_pid_after} = Ezagent.KindRegistry.lookup(session)

    assert session_pid_before == session_pid_after,
           "the deny must hold WITHOUT re-activating the session (no reconcile)"
  end

  # §14.5(A) PRIMARY prevention flow (steps 1-4) — added in Phase C (Task C.4):
  # B (no manage-authority) adds A's-agent → PENDING, no cap; B posts → A's-agent
  # :receive DENIED, does NOT run, credential not spent (PRIMARY); A notified; A
  # approves → mounts → receives.
  @tag :skip
  test "§14.5(A) steps 1-4 [PRIMARY prevention]: pending cannot receive → approve → mounts (Phase C)" do
    flunk("Phase C — Task C.4")
  end

  # §14.5(A) step 6 — cascade notify to X (Phase B / Task B.4). The GENERIC
  # cascade: a member-cap grant/revoke to an arbitrary entity X notifies X's
  # owner/manager Y (content-free). Y holds a Manage cap over X, so
  # `managers_of(X) ∋ Y`; the member-cap grant at join (and the removal-revoke)
  # each mutate X's `:identity` slice → the `{entity, :identity}` cascade fires →
  # Y's inbox gets the content-free `entity_slice_changed` envelope. This closes
  # the S1 removal-notify gap. (The cross-owner-add-goes-pending flow is Phase C.)
  test "§14.5(A) step 6 [cascade]: member-cap grant AND revoke to X notify the owner/manager Y (13/14)" do
    owner = confirmed_user("owner")
    session = new_session("cascade", owner)
    agent = owned_agent(session, "cc-agent")

    # Y (= owner) holds manage-authority over X (= agent): grant a Manage cap over
    # the agent into owner's durable identity so `managers_of(agent) ∋ owner`.
    grant_manage_cap(owner, agent)
    wait_until(fn -> owner in Ezagent.Identity.Cascade.managers_of(agent) end)

    :ok = Ezagent.Notifications.subscribe(owner)

    # --- test 13: member-cap GRANT (manage-authorized join) → Y notified -------
    # NOTE: a join grants X *two* caps into its `:identity` slice — the member-cap
    # (`:receive`) AND the join-authority cap (`membership.ex` provision) — each a
    # separate commit → separate cascade. So ≥2 grant-era notifications queue.
    _ = dispatch_join(session, agent)
    :ok = wait_member_cap(agent, session)

    assert_receive {:notification, ^owner, grant_notif}, 2_000
    assert grant_notif.type == :entity_slice_changed
    assert grant_notif.source == Ezagent.Identity.Cascade
    assert grant_notif.body.uri == URI.to_string(agent)
    assert grant_notif.body.slice_key == :identity
    # Content-free: NO cap values, NO member list, NO caller.
    assert Enum.sort(Map.keys(grant_notif.body)) == Enum.sort([:uri, :slice_key, :cursor, :event_at])

    # Drain ALL remaining grant-era cascade notifications to quiescence, so the
    # post-revoke assert below cannot be satisfied by a leftover grant notice
    # (grant and revoke carry an identical content-free payload).
    last_grant_cursor = drain_notifications(owner, grant_notif.body.cursor)

    # --- test 14: member-cap REVOKE (removal) → Y notified (S1 gap closed) -----
    assert {:ok, %{status: :removed}} =
             Participants.remove_participant(session, agent, op_ctx(owner, session))

    refute holds_member_cap?(agent, session), "remove must have revoked the member-cap"

    assert_receive {:notification, ^owner, revoke_notif}, 2_000
    assert revoke_notif.type == :entity_slice_changed
    assert revoke_notif.body.uri == URI.to_string(agent)
    assert revoke_notif.body.slice_key == :identity
    # Provably POST-revoke: the mailbox was drained, and the revoke's cursor is
    # strictly newer than every grant-era notification.
    assert revoke_notif.body.cursor > last_grant_cursor
  end

  # Consume every queued cascade notification for `owner`, returning the highest
  # cursor seen (≥ `seed`). Quiescent after 300ms of silence.
  defp drain_notifications(owner, seed) do
    receive do
      {:notification, ^owner, %{cursor: c}} -> drain_notifications(owner, max(seed, c))
    after
      300 -> seed
    end
  end

  # Grant a Manage-over-`target` cap into `holder`'s durable identity (admin).
  defp grant_manage_cap(holder, target) do
    cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        target,
        Capability.workspace_of(target),
        holder
      )

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: URI.new!("#{URI.to_string(holder)}?action=identity.grant_cap"),
      mode: :call,
      args: %{cap: cap},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: :ignore
      }
    })
  end

  defp wait_until(fun, retries \\ 200) do
    cond do
      fun.() -> :ok
      retries > 0 -> Process.sleep(10); wait_until(fun, retries - 1)
      true -> flunk("condition never became true")
    end
  end
end
