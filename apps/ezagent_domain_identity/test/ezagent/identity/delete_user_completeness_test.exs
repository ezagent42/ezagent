defmodule Ezagent.Identity.DeleteUserCompletenessTest do
  @moduledoc """
  D-4 runtime completeness proof for generation-keyed user deletion.

  These tests cover both authority axes and the no-live-window fence across a
  transitive, append-only derivation closure. They also prove revocation is
  scoped, restart cannot re-mint after a bump, cleanup failure is non-fatal,
  and an interrupted cascade is durably denied until retry converges.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Grant}
  alias Ezagent.Identity.Offboarding.RevocationFence
  alias Ezagent.Identity.Test.{BusyDeleteUserAgentKind, DeleteUserAgentKind}
  alias Ezagent.Provenance.DerivationEdges
  alias Ezagent.{Cap, Capability, IdentityCaps, Invocation, SnapshotStore, Users}

  test "an owned agent is revoked at load, authenticate, authorize, and dispatch" do
    user = create_user("owned")
    agent = unique_agent("owned")
    %{pid: pid, action_cap: cap, pat: pat} = spawn_agent(agent)
    record_edge(agent, user)

    assert Process.alive?(pid)
    assert [_ | _] = IdentityCaps.load(agent)
    assert {:ok, ^agent} = Ezagent.Entity.Token.authenticate(pat)
    assert {:ok, ^cap} = Cap.authorize(agent, [cap], needed_for_agent(agent))
    assert_dispatches(agent, cap)

    assert :ok = Users.delete(user)

    refute Process.alive?(pid)
    assert IdentityCaps.load(agent) == []
    assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(pat)
    assert {:error, :holder_revoked} = Cap.authorize(agent, [cap], needed_for_agent(agent))
    assert {:error, _reason} = dispatch(agent, cap)
  end

  test "grandchild and great-grandchild revoke while an independent agent remains current" do
    user = create_user("nested")
    child = unique_agent("child")
    grandchild = unique_agent("grandchild")
    great_grandchild = unique_agent("great-grandchild")
    independent = unique_agent("independent")

    derived = [child, grandchild, great_grandchild]

    fixtures =
      Map.new(derived ++ [independent], fn uri ->
        fixture = spawn_agent(uri)
        {uri, fixture}
      end)

    record_edge(child, user)
    record_edge(grandchild, child)
    record_edge(great_grandchild, grandchild)

    generations = Map.new(derived ++ [independent], &{&1, generation(&1)})

    assert MapSet.new(DerivationEdges.descendants(user)) == MapSet.new(derived)
    assert_dispatches(independent, fixtures[independent].action_cap)

    assert :ok = Users.delete(user)

    Enum.each(derived, fn uri ->
      fixture = fixtures[uri]
      assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(fixture.pat)
      assert IdentityCaps.load(uri) == []
      assert latest_generation(uri) == generations[uri] + 1
      refute Process.alive?(fixture.pid)
    end)

    independent_fixture = fixtures[independent]
    assert {:ok, ^independent} = Ezagent.Entity.Token.authenticate(independent_fixture.pat)
    assert [_ | _] = IdentityCaps.load(independent)
    assert generation(independent) == generations[independent]
    assert Process.alive?(independent_fixture.pid)
    assert_dispatches(independent, independent_fixture.action_cap)
  end

  test "a bumped busy principal is inert, queued, and cannot recredential after restart" do
    user = create_user("busy")
    agent = unique_agent("busy")

    %{pid: first_pid, action_cap: cap, pat: pat} =
      spawn_agent(agent, BusyDeleteUserAgentKind)

    record_edge(agent, user)

    assert :ok = Users.delete(user)

    assert Process.alive?(first_pid)
    assert IdentityCaps.load(agent) == []
    assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(pat)

    assert {:error, :holder_revoked} =
             Cap.authorize(agent, [cap], needed_for_agent(agent))

    assert {:error, _reason} = dispatch(agent, cap)
    assert agent in Ezagent.Identity.ReapQueue.pending()
    assert {:error, :authority_unavailable} = Ezagent.Entity.Token.mint(agent)

    assert :ok = DynamicSupervisor.terminate_child(Ezagent.KindSupervisor, first_pid)
    assert :ok = SnapshotStore.delete(agent)
    refute Ezagent.Lifecycle.fresh_create?(agent)

    assert {:error, {:authority_load_failed, :regenesis_required}} =
             Ezagent.Kind.spawn(BusyDeleteUserAgentKind, %{uri: agent, initial_caps: []})

    assert IdentityCaps.load(agent) == []
    assert {:error, :authority_unavailable} = Ezagent.Entity.Token.mint(agent)

    assert {:error, :holder_revoked} =
             Cap.authorize(agent, [cap], needed_for_agent(agent))

    assert :ok = Ezagent.Identity.ReapQueue.resolve(agent)
  end

  test "busy teardown cleanup converges when the process later becomes reapable" do
    user = create_user("reap")
    agent = unique_agent("reap")

    %{pid: pid, pat: pat} = spawn_agent(agent, BusyDeleteUserAgentKind)
    record_edge(agent, user)

    assert :ok = Users.delete(user)
    assert Process.alive?(pid)
    assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(pat)
    assert agent in Ezagent.Identity.ReapQueue.pending()

    assert :ok = DynamicSupervisor.terminate_child(Ezagent.KindSupervisor, pid)
    assert :ok = Ezagent.Identity.ReapQueue.sweep()

    refute agent in Ezagent.Identity.ReapQueue.pending()
    assert {:error, :not_found} = SnapshotStore.latest(agent)
  end

  test "an interrupted fenced cascade stays denied and an idempotent retry converges" do
    user = create_user("retry")
    agent = unique_agent("retry")
    %{action_cap: cap, pat: pat} = spawn_agent(agent)
    record_edge(agent, user)

    user_generation = generation(user)
    agent_generation = generation(agent)

    # Simulate the durable enrollment commit followed by a crash after only U
    # advances. The descendant remains generation-current but cannot act.
    assert :ok = RevocationFence.enroll([user, agent])
    assert generation(agent) == agent_generation
    assert RevocationFence.fenced?(agent)
    assert IdentityCaps.load(agent) == []
    assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(pat)

    assert {:error, :holder_revoked} =
             Cap.authorize(agent, [cap], needed_for_agent(agent))

    assert {:ok, _bumped_user} = Authority.regenesis(user, :user)
    assert :ok = IdentityCaps.clear_self_license_persisted(user)
    assert :ok = RevocationFence.clear(user)
    refute RevocationFence.fenced?(user)
    assert RevocationFence.fenced?(agent)

    # Retrying the public operation re-enrolls the same closure, advances the
    # still-current descendant, clears every fence, and remains idempotent.
    assert :ok = Users.delete(user)
    assert :ok = Users.delete(user)

    assert latest_generation(user) == user_generation + 2
    assert latest_generation(agent) == agent_generation + 1
    refute RevocationFence.fenced?(user)
    refute RevocationFence.fenced?(agent)
    assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(pat)
  end

  defp create_user(suffix) do
    uri = Ezagent.URI.user("delete-user-completeness", unique_name(suffix))
    assert {:ok, _row} = Users.create(uri, nil, [self_license(uri, :user)])
    uri
  end

  defp spawn_agent(uri, kind \\ DeleteUserAgentKind) do
    action_cap = action_cap(uri)
    assert {:ok, pid} = Ezagent.Kind.spawn(kind, %{uri: uri, initial_caps: [action_cap]})
    track_pid(pid)
    await_ready(uri)
    assert {pat, _row} = Ezagent.Entity.Token.mint(uri, label: "before-delete")
    %{pid: pid, action_cap: action_cap, pat: pat}
  end

  defp action_cap(uri) do
    assert {:ok, authority} = Authority.open(uri, :agent)
    intent = Grant.freeze(uri, uri, uri, requested_action(uri))

    assert {:ok, cap} =
             Authority.with_current(authority, fn -> Authority.issue_current(intent) end)

    cap
  end

  defp requested_action(uri) do
    Capability.cap(
      :any,
      Ezagent.ActionSet.Identity,
      :list_caps,
      uri,
      Capability.workspace_of(uri)
    )
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

  defp record_edge(child, parent) do
    assert :ok =
             DerivationEdges.record_derivation_edge(
               child,
               parent,
               :spawned_by,
               DerivationEdges.new_attempt_id()
             )
  end

  defp assert_dispatches(agent, cap) do
    assert {:ok, %{caps: caps}} = dispatch(agent, cap)
    assert is_list(caps)
  end

  defp dispatch(agent, cap) do
    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(agent, :identity, :list_caps),
      mode: :call,
      args: %{},
      ctx: %{
        caller: agent,
        authenticated_principal: agent,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp needed_for_agent(agent),
    do: Map.take(requested_action(agent), [:kind, :behavior, :action, :instance, :workspace_uri])

  defp generation(uri) do
    assert {:ok, generation} = Authority.current_generation(uri)
    generation
  end

  defp latest_generation(uri) do
    assert [%{generation: generation} | _] =
             uri
             |> Ezagent.URI.stable_key()
             |> Ezagent.Ecto.KindCapAuthority.list()
             |> Enum.sort_by(& &1.generation, :desc)

    generation
  end

  defp track_pid(pid) do
    on_exit(fn ->
      if Process.alive?(pid) do
        _ = DynamicSupervisor.terminate_child(Ezagent.KindSupervisor, pid)
      end
    end)

    pid
  end

  defp unique_agent(suffix) do
    Ezagent.URI.agent("delete-user-completeness", unique_name(suffix))
  end

  defp unique_name(suffix), do: "#{suffix}-#{System.unique_integer([:positive])}"

  defp await_ready(uri, attempts \\ 200)
  defp await_ready(_uri, 0), do: flunk("principal did not become ready")

  defp await_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready -> :ok
      _ -> Process.sleep(10) && await_ready(uri, attempts - 1)
    end
  end
end
