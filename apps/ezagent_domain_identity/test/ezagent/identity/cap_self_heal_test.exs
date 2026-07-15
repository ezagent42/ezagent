defmodule Ezagent.Identity.CapSelfHealTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.EntityCaps.UserStore
  alias EzagentCore.Repo

  test "activation enqueues a post-ready heal that converges caps_json and the live identity slice" do
    holder = user_uri("lifecycle")
    legacy = legacy_identity_cap(holder)
    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [legacy])

    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(holder)
    on_exit(fn -> Ezagent.Kind.terminate(holder) end)

    assert_eventually(fn ->
      case UserStore.load(holder) do
        [artifact] -> Ezagent.Cap.signed_and_valid?(artifact, holder)
        _ -> false
      end
    end)

    assert_eventually(fn ->
      case Ezagent.Kind.get_slice(holder, :identity) do
        {:ok, %{caps: caps}} ->
          Enum.any?(caps, fn cap ->
            Ezagent.Capability.identity_key(cap) == Ezagent.Capability.identity_key(legacy) and
              Ezagent.Cap.signed_and_valid?(cap, holder)
          end)

        _ ->
          false
      end
    end)

    assert Ezagent.Identity.CapQuarantine.list_open(holder) == []
  end

  test "caps_json CAS refuses a same-identity artifact with different provenance" do
    holder = user_uri("aba")
    expected = legacy_identity_cap(holder)
    newer = %{expected | granted_at: DateTime.add(expected.granted_at, 1, :second)}
    replacement = Ezagent.Test.CapHelper.issue!(holder, expected)

    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [newer])

    assert :no_match = UserStore.heal_exact(holder, expected, replacement)
    assert UserStore.load(holder) == [newer]
  end

  test "caps_json heal fails closed without erasing a valid cap beside malformed JSON" do
    holder = user_uri("malformed-sibling")
    expected = legacy_identity_cap(holder)
    replacement = Ezagent.Test.CapHelper.issue!(holder, expected)
    malformed = %{"kind" => "user", "malformed" => true}
    original_json = Jason.encode!([Ezagent.Capability.to_map(expected), malformed])

    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [])
    row = Repo.get_by!(Ezagent.Users, uri: URI.to_string(holder))
    row |> Ecto.Changeset.change(caps_json: original_json) |> Repo.update!()

    assert {:error, _reason} = UserStore.heal_exact(holder, expected, replacement)

    persisted = Repo.get_by!(Ezagent.Users, uri: URI.to_string(holder)).caps_json
    assert persisted == original_json
    assert {:ok, [valid, ^malformed]} = Jason.decode(persisted)
    assert valid == Ezagent.Capability.to_map(expected)
  end

  test "canonical revoke clears caps_json so a delayed heal cannot resurrect the cap" do
    holder = user_uri("revoke-before-delayed-heal")
    expected = legacy_identity_cap(holder)
    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [expected])
    insert_snapshot!(holder, expected)

    revoke_ctx = %{
      caller: Ezagent.Entity.User.admin_uri(),
      self_uri: holder,
      caps: MapSet.new(),
      read: fn :caps, _default -> MapSet.new([expected]) end
    }

    assert {:ok, %{caps: []}, revoke_effects} =
             Ezagent.ActionSet.IdentityAdmin.handle_revoke_cap(%{cap: expected}, revoke_ctx)

    assert {:set, :caps, %MapSet{} = live_caps} =
             Enum.find(revoke_effects, &match?({:set, :caps, _}, &1))

    assert MapSet.size(live_caps) == 0
    assert UserStore.load(holder) == []

    assert {:ok, _snapshot} =
             Ezagent.SnapshotStore.write(
               holder,
               %{identity: %{state: %{caps: live_caps}, transients: %{}}},
               kind_type: :user
             )

    request = %Ezagent.Cap.HealRequest{
      expected: expected,
      class: :identity_self,
      action: {:reissue, {:admin, Ezagent.Entity.User.admin_uri()}}
    }

    delayed_ctx = %{
      caller: :vm_internal,
      self_uri: holder,
      read: fn :caps, _default -> live_caps end
    }

    assert {:ok, %{status: :stale}, []} =
             Ezagent.ActionSet.IdentityAdmin.handle_heal_cap(%{request: request}, delayed_ctx)

    assert UserStore.load(holder) == []

    assert {:ok, %{state: %{identity: %{state: %{caps: snapshot_caps}}}}} =
             Ezagent.SnapshotStore.latest(holder)

    assert Enum.empty?(snapshot_caps)
  end

  test "a user-home-only exact artifact materializes its healed replacement in the live slice" do
    holder = user_uri("user-home-only")
    other = user_uri("other-receiver")
    expected = Ezagent.Test.CapHelper.issue!(other, legacy_sandbox_cap(holder))

    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [expected])

    request = %Ezagent.Cap.HealRequest{
      expected: expected,
      class: :agent_sandbox_self,
      action: {:reissue, {:admin, Ezagent.Entity.User.admin_uri()}}
    }

    ctx = %{
      caller: :vm_internal,
      self_uri: holder,
      read: fn :caps, _default -> MapSet.new() end
    }

    assert {:ok, %{status: :healed}, effects} =
             Ezagent.ActionSet.IdentityAdmin.handle_heal_cap(%{request: request}, ctx)

    assert {:set, :caps, %MapSet{} = healed_caps} =
             Enum.find(effects, &match?({:set, :caps, _caps}, &1))

    assert [replacement] = MapSet.to_list(healed_caps)
    assert Ezagent.Cap.signed_and_valid?(replacement, holder)
    assert [replacement] == UserStore.load(holder)
  end

  test "a heal executed after revoke is stale and does not resurrect the removed artifact" do
    holder = user_uri("revoked-before-execute")
    expected = legacy_sandbox_cap(holder)
    EzagentDomainIdentity.CapSigningTestHelpers.create_legacy_user!(holder, nil, [])

    request = %Ezagent.Cap.HealRequest{
      expected: expected,
      class: :agent_sandbox_self,
      action: {:reissue, {:admin, Ezagent.Entity.User.admin_uri()}}
    }

    ctx = %{
      caller: :vm_internal,
      self_uri: holder,
      read: fn :caps, _default -> MapSet.new() end
    }

    assert {:ok, %{status: :stale}, []} =
             Ezagent.ActionSet.IdentityAdmin.handle_heal_cap(%{request: request}, ctx)

    assert UserStore.load(holder) == []
  end

  defp legacy_identity_cap(holder) do
    %Ezagent.Capability{
      kind: :user,
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: Ezagent.URI.instance(holder),
      workspace_uri: Ezagent.Capability.workspace_of(holder),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp legacy_sandbox_cap(holder) do
    %Ezagent.Capability{
      kind: :user,
      behavior: Ezagent.ActionSet.Sandbox,
      action: :update_config,
      instance: Ezagent.URI.instance(holder),
      workspace_uri: Ezagent.Capability.workspace_of(holder),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp insert_snapshot!(holder, cap) do
    state = %{identity: %{state: %{caps: MapSet.new([cap])}, transients: %{}}}

    {:ok, _row} =
      Ezagent.Test.SnapshotFixtures.upsert_kind_snapshot(
        URI.to_string(holder),
        "user",
        :erlang.term_to_binary(state),
        0,
        "workspace://team-alpha"
      )
  end

  defp user_uri(prefix) do
    Ezagent.URI.new!("entity://team-alpha/user/#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
