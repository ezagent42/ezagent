defmodule Ezagent.UnifiedRevocationAcceptanceTest do
  @moduledoc """
  G-4/G-5 unified generation-revocation acceptance matrix.

  The suite crosses both revocation axes: candidate caps remain inert after a
  target bump whether sourced from a durable holder slice or supplied inline;
  deliberate URI reuse creates a strictly newer target authority and a fresh
  self-license; gone/unreadable authorities fail closed; per-holder removal is
  generation-neutral; unrelated authorities survive another target's bump;
  and unsigned scope tuples are grant bounds only, never access credentials.
  """

  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Cap.{Authority, AuthorityCache}
  alias Ezagent.{Cap, Capability, EntityCaps}
  alias Ezagent.Ecto.{KindCapAuthority, KindSnapshot}
  alias Ezagent.Test.TestBehavior

  @moduletag :umbrella_only

  defmodule PrincipalTargetKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :agent

    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.Test.TestBehavior]

    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])
    admin = admin()

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(admin) => MapSet.new([:admin_self_license])
    })

    :ok = Ezagent.BehaviorRegistry.register(PrincipalTargetKind, :noop, TestBehavior)

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    :ok
  end

  test "dormant slice and inline caps both deny immediately after a target bump" do
    target = spawn_target("dormant")
    holder = provision_holder("dormant")
    cap = issue!(holder, target)

    assert :ok = EntityCaps.grant(holder, cap)
    assert cap in EntityCaps.load(holder)
    assert {:ok, ^cap} = Cap.authorize(holder, [cap], needed_for(target))

    assert {:ok, bumped} = Authority.regenesis(target, :agent)

    # The stale artifact remains physically present in the holder slice, but
    # neither that source nor a direct inline presentation can authorize.
    assert cap in EntityCaps.load(holder)

    assert {:error, :no_matching_cap} =
             Cap.authorize(holder, EntityCaps.load(holder), needed_for(target))

    assert {:error, :no_matching_cap} = Cap.authorize(holder, [cap], needed_for(target))
    assert bumped.generation == 2
  end

  test "delete then deliberate recreate regenesis-es the URI and mints a new self-license" do
    target = spawn_target("reuse")
    holder = licensed_holder("reuse")
    old_cap = issue!(holder, target)
    [old_license] = self_licenses(EntityCaps.load(target))
    old_generation = generation(target)

    assert :ok = Ezagent.Lifecycle.destroy(target, :g4_recreate)
    assert KindSnapshot.get(Ezagent.URI.stable_key(target)) == nil
    assert KindCapAuthority.active(Ezagent.URI.stable_key(target)) == nil

    assert {:ok, _pid} = Ezagent.Kind.spawn(PrincipalTargetKind, %{uri: target, initial_caps: []})
    wait_until_ready(target)

    [new_license] = self_licenses(EntityCaps.load(target))
    assert generation(target) == old_generation + 1
    refute old_license.key_id == new_license.key_id
    assert Authority.verify_against_current(new_license, target, target)

    new_cap = issue!(holder, target)
    assert {:error, :no_matching_cap} = Cap.authorize(holder, [old_cap], needed_for(target))
    assert {:ok, ^new_cap} = Cap.authorize(holder, [new_cap], needed_for(target))
  end

  test "gone and unreadable target authorities both fail closed" do
    gone = spawn_target("gone")
    holder = licensed_holder("fail-closed")
    gone_cap = issue!(holder, gone)

    assert :ok = Authority.retire(gone)

    assert {:error, :no_matching_cap} =
             Cap.authorize(holder, [gone_cap], needed_for(gone))

    unreadable = spawn_target("unreadable")
    unreadable_cap = issue!(holder, unreadable)
    row = KindCapAuthority.active(Ezagent.URI.stable_key(unreadable))

    :ets.delete(AuthorityCache.table(), row.key_id)

    from(authority in KindCapAuthority,
      where: authority.uri == ^row.uri and authority.generation == ^row.generation
    )
    |> EzagentCore.Repo.update_all(set: [public_key: <<0>>])

    assert {:error, :no_matching_cap} =
             Cap.authorize(holder, [unreadable_cap], needed_for(unreadable))
  end

  test "single-holder revoke removes only that artifact and does not bump generation" do
    target = spawn_target("single-holder")
    holder = licensed_holder("single-holder")
    cap = issue!(holder, target)
    before = generation(target)

    assert {:ok, remaining} = Capability.revoke(MapSet.new([cap]), cap)
    assert generation(target) == before
    assert {:error, :no_matching_cap} = Cap.authorize(holder, remaining, needed_for(target))
  end

  test "an unrelated target and the admin genesis invariant survive another target bump" do
    bumped_target = spawn_target("isolated-a")
    independent_target = spawn_target("isolated-b")
    holder = licensed_holder("isolated")
    independent_cap = issue!(holder, independent_target)
    independent_generation = generation(independent_target)

    assert Capability.admin_invariant?(Capability.admin_genesis_cap())

    assert {:error, :cannot_revoke_admin} =
             Capability.revoke(
               MapSet.new([Capability.admin_genesis_cap()]),
               Capability.admin_genesis_cap()
             )

    assert {:ok, _authority} = Authority.regenesis(bumped_target, :agent)
    assert generation(independent_target) == independent_generation

    assert {:ok, ^independent_cap} =
             Cap.authorize(holder, [independent_cap], needed_for(independent_target))
  end

  test "unsigned within_session scope tuple is stripped at storage and denied at access" do
    target = spawn_target("scope")
    holder = licensed_holder("scope")
    session = Ezagent.URI.session(:team_alpha, :default, "scope")

    scope_cap = %Capability{
      kind: :agent,
      behavior: TestBehavior,
      action: :noop,
      instance: {:within_session, session},
      workspace_uri: Ezagent.URI.workspace(:team_alpha),
      granted_by: admin(),
      granted_at: DateTime.utc_now(),
      grantee_uri: holder
    }

    assert Cap.verified_set([scope_cap], holder) == MapSet.new()
    assert EntityCaps.verified_set([scope_cap], holder) == MapSet.new()

    assert {:error, :no_matching_cap} =
             Cap.authorize(holder, [scope_cap], needed_for(target))
  end

  defp spawn_target(suffix) do
    target =
      Ezagent.URI.agent(
        "unified-revocation",
        "#{suffix}-#{System.unique_integer([:positive])}"
      )

    assert {:ok, _pid} = Ezagent.Kind.spawn(PrincipalTargetKind, %{uri: target, initial_caps: []})
    wait_until_ready(target)

    on_exit(fn ->
      _ = Ezagent.Lifecycle.destroy(target, :test_cleanup)
    end)

    target
  end

  defp provision_holder(suffix) do
    holder = licensed_holder(suffix)
    assert {:ok, _user} = Ezagent.Users.create(holder, nil, [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(holder)
    holder
  end

  defp licensed_holder(suffix) do
    holder =
      Ezagent.URI.user(
        "unified-revocation",
        "#{suffix}-holder-#{System.unique_integer([:positive])}"
      )

    licenses = Application.get_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{})

    Application.put_env(
      :ezagent_core,
      EzagentCore.Test.CapAuthorityLoaderStub,
      Map.put(licenses, Ezagent.URI.stable_key(holder), MapSet.new([:holder_self_license]))
    )

    holder
  end

  defp issue!(holder, target) do
    assert {:ok, cap} = Cap.issue({:admin, admin()}, holder, requested(target))
    cap
  end

  defp requested(target) do
    Capability.cap(
      :agent,
      TestBehavior,
      :noop,
      target,
      Capability.workspace_of(target)
    )
  end

  defp needed_for(target) do
    %{
      kind: :agent,
      behavior: TestBehavior,
      action: :noop,
      instance: target,
      workspace_uri: Capability.workspace_of(target)
    }
  end

  defp self_licenses(caps),
    do: Enum.filter(caps, &(Capability.action_of(&1) == :self_license))

  defp generation(target) do
    target
    |> Ezagent.URI.stable_key()
    |> KindCapAuthority.active()
    |> Map.fetch!(:generation)
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)

  defp wait_until_ready(uri, attempts \\ 100)
  defp wait_until_ready(_uri, 0), do: flunk("target did not become ready")

  defp wait_until_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        wait_until_ready(uri, attempts - 1)
    end
  end
end
