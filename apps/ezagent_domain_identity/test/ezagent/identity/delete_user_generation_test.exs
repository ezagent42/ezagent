defmodule Ezagent.Identity.DeleteUserGenerationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Grant}
  alias Ezagent.Identity.Offboarding.RevocationFence
  alias Ezagent.Identity.Test.DeleteUserAgentKind
  alias Ezagent.{Capability, EntityCaps, SnapshotStore, Users}

  test "delete_user fences first, bumps the user and every derived agent, and leaves peers current" do
    user = unique_user("owner")
    derived = unique_agent("derived")
    independent = unique_agent("independent")

    user_license = self_license(user, :user)
    independent_license = self_license(independent, :agent)

    assert {:ok, _row} = Users.create(user, nil, [user_license])
    assert {pat, _row} = Ezagent.Entity.Token.mint(user, label: "before-delete")

    assert {:ok, derived_pid} =
             Ezagent.Kind.spawn(DeleteUserAgentKind, %{uri: derived, initial_caps: []})

    on_exit(fn ->
      if Process.alive?(derived_pid), do: Ezagent.Kind.terminate(derived)
    end)

    await_ready(derived)
    write_agent_caps(independent, [independent_license])

    shared_workspace = Ezagent.URI.workspace("delete-user-generation")

    assert :ok =
             Ezagent.Provenance.DerivationEdges.record_derivation_edge(
               derived,
               user,
               :spawned_by,
               Ezagent.Provenance.DerivationEdges.new_attempt_id()
             )

    # The full fence closure deliberately reaches structural descendants, but
    # workspace ownership is not agent ownership. An agent merely living in a
    # workspace that U owned must survive U's deletion.
    assert :ok =
             Ezagent.Provenance.DerivationEdges.record_derivation_edge(
               shared_workspace,
               user,
               :workspace_ownership,
               Ezagent.Provenance.DerivationEdges.new_attempt_id()
             )

    assert :ok =
             Ezagent.Provenance.DerivationEdges.record_derivation_edge(
               independent,
               shared_workspace,
               :creation_root,
               Ezagent.Provenance.DerivationEdges.new_attempt_id()
             )

    assert {:ok, user_generation} = Authority.current_generation(user)
    assert {:ok, derived_generation} = Authority.current_generation(derived)
    assert {:ok, independent_generation} = Authority.current_generation(independent)
    assert [_ | _] = EntityCaps.load_persisted(derived)
    assert [_ | _] = EntityCaps.load_persisted(independent)

    assert :ok = Users.delete(user)

    assert [%{generation: next_user_generation} | _] = authority_rows_desc(user)
    assert next_user_generation == user_generation + 1
    assert Ezagent.Ecto.KindCapAuthority.active(Ezagent.URI.stable_key(user)) == nil
    assert {:ok, next_derived_generation} = Authority.current_generation(derived)
    assert next_derived_generation == derived_generation + 1
    assert {:ok, ^independent_generation} = Authority.current_generation(independent)

    assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(pat)
    assert EntityCaps.load(derived) == []
    assert EntityCaps.load_persisted(derived) == []
    assert Process.alive?(derived_pid)
    assert [_ | _] = EntityCaps.load_persisted(independent)

    refute RevocationFence.fenced?(user)
    refute RevocationFence.fenced?(derived)
    refute RevocationFence.fenced?(independent)
    assert Users.get_by_uri(user) == nil

    assert {:ok, %{state: state}} = SnapshotStore.latest(derived)

    refute Enum.any?(get_in(state, [:identity, :state, :caps]) || [], fn cap ->
             Capability.action_of(cap) == :self_license
           end)
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

  defp write_agent_caps(uri, caps) do
    assert {:ok, _version} =
             SnapshotStore.write(
               uri,
               %{identity: %{state: %{caps: MapSet.new(caps)}, transients: %{}}},
               kind_type: :agent
             )
  end

  defp unique_user(suffix) do
    Ezagent.URI.user("delete-user-generation", unique_name(suffix))
  end

  defp unique_agent(suffix) do
    Ezagent.URI.agent("delete-user-generation", unique_name(suffix))
  end

  defp unique_name(suffix) do
    "#{suffix}-#{System.unique_integer([:positive])}"
  end

  defp await_ready(uri, attempts \\ 200)

  defp await_ready(_uri, 0), do: flunk("derived agent did not become ready")

  defp await_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        await_ready(uri, attempts - 1)
    end
  end

  defp authority_rows_desc(uri) do
    uri
    |> Ezagent.URI.stable_key()
    |> Ezagent.Ecto.KindCapAuthority.list()
    |> Enum.sort_by(& &1.generation, :desc)
  end
end
