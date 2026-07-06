defmodule Ezagent.ActionSet.DealScoutRenderTest do
  use ExUnit.Case, async: true
  alias Ezagent.ActionSet.DealScoutRender

  test "DealScoutRender is a cap-only render ActionSet with the unique :dealscout_render action" do
    assert DealScoutRender.actions() == [:dealscout_render]
    assert DealScoutRender.dispatchable?() == false
    assert Map.has_key?(DealScoutRender.required_caps(), :dealscout_render)
  end

  test "render_tree groups discoveries by source_type into a serializable json-render map" do
    items = [
      %{source_type: :public, title: "某基金完成融资"},
      %{source_type: :directed, title: "定向线索"}
    ]

    tree = DealScoutRender.render_tree(items)

    assert tree.component == :dealscout_feed
    public = Enum.find(tree.groups, &(&1.source_type == :public))
    directed = Enum.find(tree.groups, &(&1.source_type == :directed))
    assert [%{title: "某基金完成融资"}] = public.items
    assert [%{title: "定向线索"}] = directed.items
  end

  test "render_tree on no discoveries yields both (empty) groups, never crashes" do
    tree = DealScoutRender.render_tree([])
    assert Enum.map(tree.groups, & &1.source_type) |> Enum.sort() == [:directed, :public]
    assert Enum.all?(tree.groups, &(&1.items == []))
  end
end
