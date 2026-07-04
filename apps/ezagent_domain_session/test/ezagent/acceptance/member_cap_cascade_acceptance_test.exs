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

  # §14.5(A) step 6 — cascade notify to X — added in Phase B (Task B.4).
  @tag :skip
  test "§14.5(A) step 6 [cascade]: member-cap slice-change notifies the manager (Phase B)" do
    flunk("Phase B — Task B.4")
  end
end
