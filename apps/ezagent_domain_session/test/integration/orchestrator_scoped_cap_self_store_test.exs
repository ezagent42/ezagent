defmodule EzagentDomainInstanceMessage.Integration.OrchestratorScopedCapSelfStoreTest do
  @moduledoc """
  S7 delegated orchestrator caps are issued by the session owner and handed to
  the orchestrator's own non-blocking absorb path. Scope construction and the
  owner's Template-cap preflight stay at the materialization site.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Session.Orchestrator.Caps

  test "a never-ready orchestrator buffers only owner-authorized scoped artifacts" do
    unique = System.unique_integer([:positive])
    workspace_name = "s7-orch-#{unique}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :default, "session-#{unique}")
    owner_uri = Ezagent.URI.user(workspace_name, "owner-#{unique}")
    orchestrator_uri = Ezagent.URI.agent(workspace_name, "orchestrator-#{unique}")

    {:ok, _user} = Ezagent.Users.create(owner_uri, nil, [])
    {:ok, owner_pid} = Ezagent.SpawnRegistry.spawn(owner_uri)

    {:ok, orchestrator_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: orchestrator_uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    wait_ready(owner_uri)
    wait_ready(orchestrator_uri)

    on_exit(fn ->
      _ = Ezagent.PendingDelivery.flush(orchestrator_uri)
      :ok = Ezagent.WorkspaceRegistry.unbind(session_uri)
      terminate_if_alive(orchestrator_uri, orchestrator_pid)
      terminate_if_alive(owner_uri, owner_pid)
    end)

    :ok = Ezagent.ReadyGate.put(orchestrator_uri, :not_ready)
    buffer_size_before = Ezagent.PendingDelivery.buffer_size(orchestrator_uri)

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

    # This owner holds no delegable Template cap, so the standing preflight
    # admits only the two unconditional, scope-bounded delegation artifacts.
    assert Ezagent.PendingDelivery.buffer_size(orchestrator_uri) == buffer_size_before + 2

    refute Enum.any?(Ezagent.Identity.read_entity_caps(orchestrator_uri), fn cap ->
             cap.instance in [
               {:within_session, session_uri},
               {:spawned_by, orchestrator_uri}
             ]
           end)

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(orchestrator_uri),
               orchestrator_pid
             )

    assert eventually(fn ->
             caps = Ezagent.Identity.read_entity_caps(orchestrator_uri)

             Enum.any?(
               caps,
               &scoped_cap?(&1, :session, {:within_session, session_uri}, owner_uri)
             ) and
               Enum.any?(
                 caps,
                 &scoped_cap?(&1, :agent, {:spawned_by, orchestrator_uri}, owner_uri)
               ) and
               Enum.all?(caps, fn cap ->
                 cap.behavior != Ezagent.ActionSet.Template or
                   cap.instance != {:within_workspace, workspace_uri}
               end)
           end)
  end

  defp scoped_cap?(cap, kind, instance, owner_uri) do
    cap.kind == kind and
      cap.behavior == :any and
      cap.action == :any and
      cap.instance == instance and
      cap.granted_by == owner_uri
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

  defp eventually(fun, attempts \\ 100)
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
