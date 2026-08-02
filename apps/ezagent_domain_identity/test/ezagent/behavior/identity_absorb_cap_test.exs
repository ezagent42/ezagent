defmodule Ezagent.ActionSet.IdentityAbsorbCapTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.Capability
  alias Ezagent.ActionSet.{Identity, IdentityAdmin}

  @workspace URI.new!("workspace://team-alpha")
  @issuer URI.new!("entity://team-alpha/user/issuer")
  @user URI.new!("entity://team-alpha/user/grantee")
  @agent URI.new!("entity://team-alpha/agent/grantee")

  defp artifact do
    %Capability{
      kind: :session,
      behavior: :example,
      action: :send,
      instance: URI.new!("session://team-alpha/default/main"),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now()
    }
  end

  defp signed_artifact(receiver) do
    cap = artifact()
    {:ok, authority} = Ezagent.Cap.Authority.open(cap.instance, :session)
    authority_signed_cap_as!(authority, @issuer, receiver, cap)
  end

  defp ctx(self_uri, caps \\ MapSet.new()) do
    %{
      caller: :vm_internal,
      self_uri: self_uri,
      read: fn :caps, _default -> caps end
    }
  end

  test "I2 rejects every non-VM caller without storing" do
    external = %{ctx(@user) | caller: @issuer}

    assert {:error, :unauthorized} =
             IdentityAdmin.handle_absorb_cap(%{artifact: artifact()}, external)
  end

  test "rejects an artifact that fails Cap.verify" do
    forged = %{artifact() | granted_by: URI.new!("system://forged")}

    assert {:error, :invalid_cap_artifact} =
             IdentityAdmin.handle_absorb_cap(%{artifact: forged}, ctx(@user))
  end

  test "I10 stores, emits cap_granted via_absorb, and notifies a user" do
    :ok = Ezagent.Notifications.subscribe(@user)
    cap = signed_artifact(@user)

    assert {:ok, %{caps: [^cap]}, effects} =
             IdentityAdmin.handle_absorb_cap(%{artifact: cap}, ctx(@user))

    assert {:set, :caps, stored} = Enum.find(effects, &match?({:set, :caps, _}, &1))
    assert MapSet.equal?(stored, MapSet.new([cap]))

    assert {:emit, :cap_granted, %{cap: ^cap, via_absorb: true}} =
             Enum.find(effects, &match?({:emit, :cap_granted, _}, &1))

    assert_receive {:notification, @user, %{type: :cap_granted}}, 1_000
  end

  test "agent absorb emits audit and the user-only notifier remains a no-op" do
    assert {:ok, _result, effects} =
             IdentityAdmin.handle_absorb_cap(%{artifact: signed_artifact(@agent)}, ctx(@agent))

    assert {:emit, :cap_granted, %{via_absorb: true}} =
             Enum.find(effects, &match?({:emit, :cap_granted, _}, &1))
  end

  test "a signed artifact enters only the named entity slice" do
    artifact = signed_artifact(@user)

    assert {:ok, %{caps: [^artifact]}, _effects} =
             IdentityAdmin.handle_absorb_cap(%{artifact: artifact}, ctx(@user))

    assert {:error, :invalid_cap_artifact} =
             IdentityAdmin.handle_absorb_cap(%{artifact: artifact}, ctx(@agent))
  end

  test "identity create rejects a signed artifact issued to another entity" do
    artifact = signed_artifact(@agent)

    assert {:ok, state} = Identity.create(%{uri: @user, initial_caps: [artifact]})
    refute MapSet.member?(state.caps, artifact)
  end

  test "identity activate rejects the complete carrier when any artifact names another receiver" do
    alice_artifact = signed_artifact(@user)
    agent_artifact = signed_artifact(@agent)

    assert {:ok, %{}, reconciled} =
             Identity.activate(
               %{caps: MapSet.new([alice_artifact, agent_artifact])},
               %{self_uri: @user}
             )

    refute MapSet.member?(reconciled.caps, alice_artifact)
    refute MapSet.member?(reconciled.caps, agent_artifact)
    assert reconciled.caps == MapSet.new()
  end

  test "absorbing the same identity twice replaces metadata without growing the set" do
    first = signed_artifact(@user)
    second = signed_artifact(@user)

    assert {:ok, _result, effects} =
             IdentityAdmin.handle_absorb_cap(%{artifact: second}, ctx(@user, MapSet.new([first])))

    assert {:set, :caps, stored} = Enum.find(effects, &match?({:set, :caps, _}, &1))
    assert MapSet.size(stored) == 1
    assert MapSet.member?(stored, second)
  end

  test "action is cast-only and cap-exempt before the in-handler provenance gate" do
    assert IdentityAdmin.__actions__().absorb_cap.modes == [:cast]
    assert :absorb_cap in IdentityAdmin.cap_exempt_actions()
  end
end
