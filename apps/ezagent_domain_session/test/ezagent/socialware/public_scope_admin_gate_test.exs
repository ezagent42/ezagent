defmodule Ezagent.Socialware.PublicScopeAdminGateTest do
  # SECURITY (#165) — authoring/publishing a socialware Definition whose
  # `visibility_policy.scope` is `:public` promotes it into the CROSS-TENANT
  # installable catalog, so it MUST require ADMIN authority. The gate lives at the
  # DOMAIN chokepoint (`DefinitionRegistry.write_definition/2`), NOT only the world
  # LiveView, so the raw write path is not exploitable by other callers. A
  # non-admin workspace operator (holds `:add_template`, not admin) is denied with
  # `{:error, :public_socialware_requires_admin}` and NO `socialware:<name>` object
  # is written; the SAME def written as `:private`, or the public def written by an
  # admin, succeeds. PRIVATE authoring authority is unchanged.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Socialware.{Definition, DefinitionRegistry}

  @ws Ezagent.URI.new!("workspace://team-165")
  # A non-admin workspace operator: real `:add_template` authority, NOT admin.
  @operator Ezagent.URI.new!("entity://team-165/user/operator")
  @admin Ezagent.URI.new!("entity://team-165/user/boss")

  defp uniq, do: System.unique_integer([:positive])

  defp operator_caps do
    MapSet.new([Capability.cap(:workspace, Ezagent.ActionSet.Workspace, :add_template)])
  end

  defp admin_caps do
    MapSet.new([Capability.admin_genesis_cap()])
  end

  defp def_attrs(name, scope) do
    %{
      name: name,
      title: "Gate #{name}",
      bases: [Ezagent.ActionSet.Session],
      shape: [],
      visibility_policy: %{scope: scope, publish_policy: :auto, web_anon_access: false}
    }
  end

  defp write(name, scope, caller, caps) do
    {:ok, definition} = Definition.new(def_attrs(name, scope))

    DefinitionRegistry.write_definition(definition,
      workspace_uri: @ws,
      caller_workspace_uri: @ws,
      actor_uri: caller,
      caps: caps
    )
  end

  test "non-admin operator CANNOT publish a :public socialware def, and nothing is written" do
    name = "gate-public-denied-#{uniq()}"

    assert {:error, :public_socialware_requires_admin} =
             write(name, :public, @operator, operator_caps())

    # No `socialware:<name>` object was persisted (gate runs BEFORE the write).
    assert :error = DefinitionRegistry.lookup(@ws, name)
  end

  test "non-admin operator CAN author a :private socialware def (private authority unchanged)" do
    name = "gate-private-ok-#{uniq()}"

    assert {:ok, %{} = _object} = write(name, :private, @operator, operator_caps())
    assert {:ok, %Definition{name: ^name}, _object} = DefinitionRegistry.lookup(@ws, name)
  end

  test "an admin CAN publish a :public socialware def" do
    name = "gate-public-admin-#{uniq()}"

    assert {:ok, %{} = _object} = write(name, :public, @admin, admin_caps())

    assert {:ok, %Definition{name: ^name}, _object} = DefinitionRegistry.lookup(@ws, name)
    assert Enum.any?(DefinitionRegistry.list(@ws), &(&1.name == name and &1.public? == true))
  end
end
