defmodule Ezagent.Identity.DeleteUserBusyTimeoutTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Grant}
  alias Ezagent.Identity.Test.BusyDeleteUserAgentKind
  alias Ezagent.{Cap, Capability, EntityCaps, SnapshotStore, Users}

  test "a still-live owned agent is inert after delete_user and queued for reap" do
    user = unique_user("owner")
    agent = unique_agent("busy")

    assert {:ok, _row} = Users.create(user, nil, [self_license(user, :user)])

    assert {:ok, pid} =
             Ezagent.Kind.spawn(BusyDeleteUserAgentKind, %{uri: agent, initial_caps: []})

    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(Ezagent.KindSupervisor, pid)
      end
    end)

    await_ready(agent)

    assert :ok =
             Ezagent.Provenance.DerivationEdges.record_derivation_edge(
               agent,
               user,
               :spawned_by,
               Ezagent.Provenance.DerivationEdges.new_attempt_id()
             )

    {pat, _token} = Ezagent.Entity.Token.mint(agent, label: "before-delete")
    assert [_ | _] = caps = EntityCaps.load(agent)
    license = Enum.find(caps, &(&1.action == :self_license))
    needed = Map.take(license, [:kind, :behavior, :action, :instance, :workspace_uri])

    assert {:ok, ^license} = Cap.authorize(agent, [license], needed)
    assert {:ok, ^agent} = Ezagent.Entity.Token.authenticate(pat)

    assert :ok = Users.delete(user)

    assert Process.alive?(pid)
    assert EntityCaps.load(agent) == []
    assert EntityCaps.load_persisted(agent) == []
    assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(pat)
    assert {:error, :holder_revoked} = Cap.authorize(agent, [license], needed)
    assert agent in Ezagent.Identity.ReapQueue.pending()

    assert :ok = DynamicSupervisor.terminate_child(Ezagent.KindSupervisor, pid)
    refute Process.alive?(pid)

    assert :ok = Ezagent.Identity.ReapQueue.sweep()
    refute agent in Ezagent.Identity.ReapQueue.pending()
    assert {:error, :not_found} = SnapshotStore.latest(agent)
  end

  defp self_license(principal, kind_type) do
    assert {:ok, authority} = Authority.open(principal, kind_type)

    requested =
      Capability.cap(
        kind_type,
        Ezagent.ActionSet.Identity,
        :self_license,
        principal,
        Capability.workspace_of(principal)
      )

    intent = Grant.freeze(principal, principal, principal, requested)
    assert {:ok, license} = Grant.issue_self_license(authority, intent)
    license
  end

  defp unique_user(suffix),
    do: Ezagent.URI.user("delete-user-busy", unique_name(suffix))

  defp unique_agent(suffix),
    do: Ezagent.URI.agent("delete-user-busy", unique_name(suffix))

  defp unique_name(suffix),
    do: "#{suffix}-#{System.unique_integer([:positive])}"

  defp await_ready(uri, attempts \\ 200)
  defp await_ready(_uri, 0), do: flunk("busy agent did not become ready")

  defp await_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready -> :ok
      _ -> Process.sleep(10) && await_ready(uri, attempts - 1)
    end
  end
end
