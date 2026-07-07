defmodule Ezagent.Socialware.PublishOrUpgradeTest do
  # T-R2-a / T-R2-b (§8.1) — the unified idempotency RULE on the GOVERNANCE
  # write path (the path R-2 lives on). One hash-comparison rule, NO provenance
  # guard: an edited manifest re-promotes (:upgraded), identical bytes no-op
  # (:exists).
  use EzagentCore.DataCase, async: false

  alias Ezagent.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Socialware.{Definition, DefinitionRegistry}

  @owner Ezagent.URI.new!("entity://team-alpha/user/owner")
  @ws Ezagent.URI.new!("workspace://team-alpha")

  defp uniq, do: System.unique_integer([:positive])

  defp attrs(name, overrides \\ %{}) do
    Map.merge(
      %{
        name: name,
        title: "Governed #{name}",
        description: "orig",
        bases: [Ezagent.ActionSet.Session],
        shape: [],
        visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
      },
      overrides
    )
  end

  defp ctx(name) do
    %{
      caller: @owner,
      workspace_uri: @ws,
      caps: MapSet.new([Governance.manage_cap(name, @ws, @owner)])
    }
  end

  test "T-R2-a: an edited manifest re-promotes on the governance path" do
    name = "r2-#{uniq()}"
    c = ctx(name)

    {:ok, def_v1} = Definition.new(attrs(name))
    assert {:ok, :published} = Governance.publish_or_upgrade(def_v1, c)
    {:ok, _d1, obj_v1} = DefinitionRegistry.lookup(@ws, name)

    {:ok, def_v2} = Definition.new(attrs(name, %{description: "edited body"}))
    assert {:ok, :upgraded} = Governance.publish_or_upgrade(def_v2, c)

    {:ok, _d2, obj_v2} = DefinitionRegistry.lookup(@ws, name)
    # a NEW immutable revision was minted
    refute obj_v2.id == obj_v1.id
    # the current published revision's content_hash == the edited body's hash
    assert obj_v2.content_hash == Definition.content_hash(Definition.body(def_v2))

    assert Definition.content_hash(obj_v2.body) ==
             Definition.content_hash(Definition.body(def_v2))
  end

  test "T-R2-b: a no-op re-publish with identical bytes is :exists (no new revision)" do
    name = "r2b-#{uniq()}"
    c = ctx(name)

    {:ok, def_v1} = Definition.new(attrs(name))
    assert {:ok, :published} = Governance.publish_or_upgrade(def_v1, c)
    {:ok, _d1, obj_v1} = DefinitionRegistry.lookup(@ws, name)

    assert {:ok, :exists} = Governance.publish_or_upgrade(def_v1, c)
    {:ok, _d1b, obj_after} = DefinitionRegistry.lookup(@ws, name)
    # same revision — no new object minted
    assert obj_after.id == obj_v1.id
  end
end
