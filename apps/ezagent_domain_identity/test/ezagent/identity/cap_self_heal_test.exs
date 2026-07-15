defmodule Ezagent.Identity.CapSelfHealTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.EntityCaps.UserStore

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
