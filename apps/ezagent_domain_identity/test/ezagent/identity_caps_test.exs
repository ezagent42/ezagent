defmodule Ezagent.IdentityCapsTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query
  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.{Capability, IdentityCaps}
  alias Ezagent.IdentityCaps.Store
  alias EzagentCore.Repo

  @workspace URI.new!("workspace://entity-caps")
  @issuer URI.new!("entity://entity-caps/user/issuer")

  defmodule IdentityHostKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :agent

    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.IdentityAdmin]

    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  setup do
    :ok = Ezagent.ReadyGate.register_external_gate(Ezagent.IdentityCapsReadyBarrier)
    :ok = Ezagent.IdentityCapsReadyBarrier.clear()

    for action <- [:list_caps, :has_cap?, :persist_caps, :store_cap, :remove_cap] do
      :ok =
        Ezagent.CapabilityRegistry.register(
          IdentityHostKind,
          action,
          if(action in [:persist_caps, :store_cap, :remove_cap],
            do: Ezagent.ActionSet.IdentityAdmin,
            else: Ezagent.ActionSet.Identity
          )
        )
    end

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_identity, :forced_store_failure_uris)
      Application.delete_env(:ezagent_actor, :p3_forced_snapshot_failure_uris)
      Ezagent.IdentityCapsReadyBarrier.clear()
    end)

    :ok
  end

  test "users and non-users read the same Store authority" do
    user = user_uri("same-authority")
    agent = agent_uri("same-authority")
    user_grant = issued_cap(user, :send)
    agent_grant = issued_cap(agent, :join)

    assert {:ok, _row} = Ezagent.Users.create_read_only(user, [user_grant])
    assert :ok = Ezagent.Entity.spawn_principal(user)
    wait_until_ready(user)

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: [agent_grant]})

    wait_until_ready(agent)

    assert cap_present?(IdentityCaps.load_persisted(user), user_grant)
    assert cap_present?(IdentityCaps.load_persisted(agent), agent_grant)
    assert Store.status(user) == :active
    assert Store.status(agent) == :active

    :ok = Ezagent.Kind.terminate(user)
    :ok = Ezagent.Kind.terminate(agent)
  end

  test "a missing Store row refuses established cold readiness" do
    agent = agent_uri("missing-store")
    grant = issued_cap(agent, :send)
    spawn_agent(agent, [grant])
    :ok = Ezagent.Kind.terminate(agent)

    from(row in Store, where: row.uri == ^Ezagent.URI.stable_key(agent))
    |> Repo.delete_all()

    assert {:error,
            {:identity_reconcile_failed, {:identity_reconcile_unreadable, :identity_caps_missing}}} =
             Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: []})

    assert IdentityCaps.load_persisted(agent) == []
  end

  test "a corrupt Store row refuses established cold readiness" do
    agent = agent_uri("corrupt-store")
    spawn_agent(agent, [issued_cap(agent, :send)])
    :ok = Ezagent.Kind.terminate(agent)

    from(row in Store, where: row.uri == ^Ezagent.URI.stable_key(agent))
    |> Repo.update_all(set: [caps_json: "null"])

    assert {:error,
            {:identity_reconcile_failed, {:identity_reconcile_unreadable, :invalid_caps_json}}} =
             Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: []})

    assert IdentityCaps.load_persisted(agent) == []
  end

  test "a user row and stale snapshot cannot resurrect a missing Store capability" do
    user = user_uri("no-resurrection")
    grant = issued_cap(user, :send)
    assert {:ok, _row} = Ezagent.Users.create_read_only(user, [grant])
    assert :ok = Ezagent.Entity.spawn_principal(user)
    wait_until_ready(user)
    assert cap_present?(IdentityCaps.load(user), grant)
    :ok = Ezagent.Kind.terminate(user)

    from(row in Store, where: row.uri == ^Ezagent.URI.stable_key(user))
    |> Repo.delete_all()

    assert :ok = Ezagent.Entity.spawn_principal(user)
    wait_until(fn -> Ezagent.KindRegistry.lookup(user) == :error end)
    refute Ezagent.ReadyGate.status(user) == :ready
    assert IdentityCaps.load_persisted(user) == []
  end

  test "Store failure leaves live and snapshot projections unchanged" do
    agent = agent_uri("store-failure")
    original = issued_cap(agent, :send)
    added = issued_cap(agent, :join)
    spawn_agent(agent, [original])

    Application.put_env(:ezagent_domain_identity, :forced_store_failure_uris, [
      Ezagent.URI.stable_key(agent)
    ])

    assert {:error, _reason} = IdentityCaps.grant(agent, added)
    assert cap_present?(IdentityCaps.load(agent), original)
    refute cap_present?(IdentityCaps.load(agent), added)
    refute cap_present?(IdentityCaps.load_persisted(agent), added)

    :ok = Ezagent.Kind.terminate(agent)
  end

  test "snapshot projection failure leaves Store committed and cold restart repairs live state" do
    agent = agent_uri("projection-failure")
    original = issued_cap(agent, :send)
    added = issued_cap(agent, :join)
    spawn_agent(agent, [original])

    Application.put_env(:ezagent_actor, :p3_forced_snapshot_failure_uris, [
      Ezagent.URI.stable_key(agent)
    ])

    assert :ok = IdentityCaps.grant(agent, added)
    assert cap_present?(IdentityCaps.load(agent), added)
    assert cap_present?(IdentityCaps.load_persisted(agent), added)

    :ok = Ezagent.Kind.terminate(agent)
    Application.delete_env(:ezagent_actor, :p3_forced_snapshot_failure_uris)

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: []})

    wait_until_ready(agent)
    assert cap_present?(IdentityCaps.load(agent), added)
    :ok = Ezagent.Kind.terminate(agent)
  end

  test "grant, exact revoke, and fresh re-grant survive restart" do
    agent = agent_uri("regrant")
    first = issued_cap(agent, :send)
    spawn_agent(agent, [])

    assert :ok = IdentityCaps.grant(agent, first)
    attacker_shape = %{first | grant_id: Ecto.UUID.generate()}
    assert :ok = IdentityCaps.revoke(agent, attacker_shape)
    refute cap_present?(IdentityCaps.load_persisted(agent), first)

    second = issued_cap(agent, :send)
    refute second.grant_id == first.grant_id
    assert :ok = IdentityCaps.grant(agent, second)
    :ok = Ezagent.Kind.terminate(agent)

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(IdentityHostKind, %{uri: agent, initial_caps: []})

    wait_until_ready(agent)
    assert cap_present?(IdentityCaps.load(agent), second)
    :ok = Ezagent.Kind.terminate(agent)
  end

  test "missing Store authority makes effective reads explicit failures" do
    assert {:error, :effective_caps_read_failed} =
             IdentityCaps.effective_caps_persisted(agent_uri("effective-missing"))
  end

  defp spawn_agent(uri, initial_caps) do
    assert {:ok, _pid} =
             Ezagent.Kind.spawn(IdentityHostKind, %{uri: uri, initial_caps: initial_caps})

    wait_until_ready(uri)
  end

  defp issued_cap(receiver, action) do
    unsigned = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: URI.new!("session://entity-caps/default/main"),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now(),
      grant_id: Ecto.UUID.generate()
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(unsigned.instance, :session)
    authority_signed_cap_as!(authority, @issuer, receiver, unsigned)
  end

  defp user_uri(suffix) do
    URI.new!("entity://entity-caps/user/#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp agent_uri(suffix) do
    URI.new!("entity://entity-caps/agent/#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp identity_keys(caps), do: caps |> Enum.map(&Capability.identity_key/1) |> MapSet.new()
  defp cap_present?(caps, cap), do: Capability.identity_key(cap) in identity_keys(caps)

  defp wait_until_ready(uri), do: wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
