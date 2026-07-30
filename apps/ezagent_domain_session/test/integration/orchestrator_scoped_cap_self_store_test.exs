defmodule EzagentDomainInstanceMessage.Integration.OrchestratorScopedCapSelfStoreTest do
  @moduledoc """
  S7 delegated orchestrator caps are issued by the session owner and handed to
  the orchestrator's own non-blocking absorb path. Scope construction and the
  owner's Template-cap preflight stay at the materialization site.
  """
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Cap.Delivery
  alias Ezagent.Entity.Session.Orchestrator.Caps

  test "a never-ready orchestrator persists only owner-authorized scoped artifacts" do
    unique = System.unique_integer([:positive])
    workspace_name = "s7-orch-#{unique}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :default, "session-#{unique}")
    owner_uri = Ezagent.URI.user(workspace_name, "owner-#{unique}")
    orchestrator_uri = Ezagent.URI.agent(workspace_name, "orchestrator-#{unique}")

    {:ok, _user} = Ezagent.Users.create(owner_uri, nil, [])
    {:ok, owner_pid} = Ezagent.SpawnRegistry.spawn(owner_uri)
    {:ok, workspace_pid} = Ezagent.Workspace.spawn_workspace(workspace_name, %{})

    {:ok, session_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: owner_uri
      })

    {:ok, orchestrator_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: orchestrator_uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    wait_ready(owner_uri)
    wait_ready(workspace_uri)
    wait_ready(session_uri)
    wait_ready(orchestrator_uri)
    wait_delivery_outbox_idle(orchestrator_uri)
    settle_boot_mailbox(orchestrator_pid)

    on_exit(fn ->
      _ = Ezagent.PendingDelivery.flush(orchestrator_uri)
      :ok = Ezagent.WorkspaceRegistry.unbind(session_uri)
      terminate_if_alive(orchestrator_uri, orchestrator_pid)
      terminate_if_alive(session_uri, session_pid)
      terminate_if_alive(workspace_uri, workspace_pid)
      terminate_if_alive(owner_uri, owner_pid)
    end)

    :ok = Ezagent.ReadyGate.put(orchestrator_uri, :not_ready)

    task =
      Task.async(fn ->
        receive do
          :run ->
            Caps.grant_orchestrator_scoped_caps(orchestrator_uri, session_uri, owner_uri)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), task.pid)
    send(task.pid, :run)

    assert {:ok, :ok} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    assert Ezagent.ReadyGate.status(orchestrator_uri) == :not_ready

    # A never-ready transport does not block cap handoff: each exact Session
    # or Workspace action is already signed by its concrete target authority
    # and durably queued for the orchestrator's own absorb path.
    assert [first_notification, second_notification] = pending_entries(orchestrator_uri)

    assert_cascade_notification(first_notification, orchestrator_uri, 1)
    assert_cascade_notification(second_notification, orchestrator_uri, 2)
    pending_before = pending_deliveries(orchestrator_uri)
    pending = pending_artifacts(orchestrator_uri)

    assert length(pending) == expected_cap_count()

    assert Enum.all?(pending, fn cap ->
             cap.instance in [session_uri, workspace_uri] and
               cap.grantee_uri == orchestrator_uri and is_binary(cap.signature) and
               is_binary(cap.key_id)
           end)

    assert :ok =
             Caps.grant_orchestrator_scoped_caps(orchestrator_uri, session_uri, owner_uri)

    assert Enum.map(pending_deliveries(orchestrator_uri), &{&1.id, &1.attempts}) ==
             Enum.map(pending_before, &{&1.id, &1.attempts})

    refute Enum.any?(Ezagent.Identity.read_entity_caps(orchestrator_uri), fn cap ->
             Enum.any?(
               pending,
               &(Ezagent.Capability.identity_key(&1) ==
                   Ezagent.Capability.identity_key(cap))
             )
           end)

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(orchestrator_uri),
               orchestrator_pid
             )

    assert eventually(fn ->
             caps = Ezagent.Identity.read_entity_caps(orchestrator_uri)

             Enum.all?(pending, fn expected ->
               Enum.any?(
                 caps,
                 &(Ezagent.Capability.identity_key(&1) ==
                     Ezagent.Capability.identity_key(expected))
               )
             end) and
               EzagentCore.Repo.aggregate(
                 from(delivery in Delivery,
                   where: delivery.target_uri == ^URI.to_string(orchestrator_uri),
                   where: delivery.op == :absorb_cap,
                   where: delivery.status == :pending
                 ),
                 :count
               ) == 0
           end)
  end

  defp pending_artifacts(uri) do
    uri
    |> pending_deliveries()
    |> Enum.map(fn delivery ->
      %{op: :absorb_cap, cap: cap} = :erlang.binary_to_term(delivery.payload, [:safe])
      cap
    end)
  end

  defp pending_deliveries(uri) do
    from(delivery in Delivery,
      where: delivery.target_uri == ^URI.to_string(uri),
      where: delivery.op == :absorb_cap,
      where: delivery.status == :pending,
      order_by: [asc: delivery.id]
    )
    |> EzagentCore.Repo.all()
  end

  defp pending_entries(uri) do
    Ezagent.PendingDelivery.with_lock(uri, fn ->
      key = URI.to_string(uri)

      case :ets.lookup(Ezagent.PendingDelivery.table(), key) do
        [{^key, entries}] -> Ezagent.PendingDelivery.unwrap_entries(entries)
        [] -> []
      end
    end)
  end

  defp assert_cascade_notification(invocation, orchestrator_uri, cursor) do
    assert %Ezagent.Invocation{
             target: %URI{query: "action=_.cascade_notify_managers"} = target,
             mode: :cast,
             args: %{cursor: ^cursor, slice_key: :identity, event_at: %DateTime{}},
             ctx: %{caller: :vm_internal, reply: :ignore, mode: :cast, caps: caps},
             origin: :trusted_internal
           } = invocation

    assert URI.to_string(%{target | query: nil}) == URI.to_string(orchestrator_uri)
    assert MapSet.size(caps) == 0
  end

  defp expected_cap_count do
    session_count =
      Ezagent.CapabilityRegistry.subjects_for_kind(Ezagent.Entity.Session)
      |> Enum.reject(&Ezagent.Cap.Verifier.non_cap_action?(&1.behavior, &1.action))
      |> length()

    session_count + 3
  end

  defp wait_ready(uri, attempts \\ 200)
  defp wait_ready(_uri, 0), do: flunk("Kind never became ready")

  defp wait_ready(uri, attempts) do
    if Ezagent.ReadyGate.status(uri) == :ready do
      :ok
    else
      Process.sleep(10)
      wait_ready(uri, attempts - 1)
    end
  end

  defp wait_delivery_outbox_idle(uri, attempts \\ 200)

  defp wait_delivery_outbox_idle(_uri, 0),
    do: flunk("orchestrator capability delivery outbox never became idle")

  defp wait_delivery_outbox_idle(uri, attempts) do
    pending =
      EzagentCore.Repo.aggregate(
        from(delivery in Delivery,
          where: delivery.target_uri == ^URI.to_string(uri),
          where: delivery.status == :pending
        ),
        :count
      )

    if pending == 0 do
      :ok
    else
      Process.sleep(10)
      wait_delivery_outbox_idle(uri, attempts - 1)
    end
  end

  defp settle_boot_mailbox(pid) do
    _state = :sys.get_state(pid)
    _state = :sys.get_state(pid)
    :ok
  end

  defp eventually(fun, attempts \\ 500)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp terminate_if_alive(uri, pid) when is_pid(pid) do
    if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
  end
end
