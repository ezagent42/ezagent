defmodule Ezagent.Socialware.ConfigGovernanceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Socialware.DefinitionRegistry

  @owner Ezagent.URI.new!("entity://team-alpha/user/owner")
  @stranger Ezagent.URI.new!("entity://team-alpha/user/stranger")
  @workspace_a Ezagent.URI.new!("workspace://team-alpha")
  @workspace_b Ezagent.URI.new!("workspace://team-beta")

  defp uniq, do: System.unique_integer([:positive])

  defp definition(name, scope \\ :private) do
    %{
      name: name,
      title: "Governed #{name}",
      bases: [Ezagent.ActionSet.Session],
      shape: [],
      visibility_policy: %{scope: scope, publish_policy: :auto, web_anon_access: false}
    }
  end

  defp owner_ctx(name, extra_caps \\ []) do
    %{
      caller: @owner,
      workspace_uri: @workspace_a,
      caps: MapSet.new([Governance.manage_cap(name, @workspace_a, @owner) | extra_caps])
    }
  end

  test "owner publishes a private socialware through the CR lifecycle" do
    name = "private-governed-#{uniq()}"
    ctx = owner_ctx(name)

    assert {:ok, %{cr_id: cr_id, status: "open"}} =
             Governance.open_cr(%{name: name}, ctx)

    assert {:ok, %{staged_object_id: staged_id}} =
             Governance.stage_definition(cr_id, definition(name), ctx)

    assert {:ok, %{status: "published"}} = Governance.publish_cr(cr_id, ctx)
    assert {:ok, definition, object} = DefinitionRegistry.lookup(@workspace_a, name)
    assert object.id == staged_id
    assert definition.name == name
    assert definition.visibility_policy.scope == :private
  end

  test "non-owner cannot stage or publish a socialware CR" do
    name = "owner-only-#{uniq()}"
    ctx = owner_ctx(name)

    assert {:ok, %{cr_id: cr_id}} = Governance.open_cr(%{name: name}, ctx)

    stranger_ctx = %{
      caller: @stranger,
      workspace_uri: @workspace_a,
      caps: MapSet.new()
    }

    assert {:error, :unauthorized} =
             Governance.stage_definition(cr_id, definition(name), stranger_ctx)

    assert {:error, :unauthorized} = Governance.publish_cr(cr_id, stranger_ctx)
  end

  test "public promotion is admin-gated and then visible cross-workspace" do
    name = "public-governed-#{uniq()}"
    owner = owner_ctx(name)

    assert {:ok, %{cr_id: private_cr}} = Governance.open_cr(%{name: name}, owner)
    assert {:ok, _} = Governance.stage_definition(private_cr, definition(name), owner)
    assert {:ok, %{status: "published"}} = Governance.publish_cr(private_cr, owner)

    assert {:ok, %{cr_id: public_cr}} = Governance.open_cr(%{name: name}, owner)
    assert {:ok, _} = Governance.stage_definition(public_cr, definition(name, :public), owner)

    assert {:error, :public_socialware_requires_admin} = Governance.publish_cr(public_cr, owner)

    admin_ctx = owner_ctx(name, [Ezagent.Capability.admin_genesis_cap()])
    assert {:ok, %{status: "published"}} = Governance.publish_cr(public_cr, admin_ctx)

    visible = DefinitionRegistry.list(@workspace_b)
    assert Enum.any?(visible, &(&1.name == name and &1.public? == true))
  end

  test "private socialware remains invisible cross-workspace" do
    name = "private-hidden-#{uniq()}"
    ctx = owner_ctx(name)

    assert {:ok, %{cr_id: cr_id}} = Governance.open_cr(%{name: name}, ctx)
    assert {:ok, _} = Governance.stage_definition(cr_id, definition(name), ctx)
    assert {:ok, %{status: "published"}} = Governance.publish_cr(cr_id, ctx)

    refute Enum.any?(DefinitionRegistry.list(@workspace_b), &(&1.name == name))
  end
end
