defmodule EzagentPluginDealScout.DealScoutViewTest do
  use ExUnit.Case, async: true
  alias EzagentPluginDealScout.DealScoutView

  test "declares the Ezagent.UI.SessionView contract fields" do
    assert DealScoutView.id() == :dealscout_feed
    assert is_binary(DealScoutView.label()) and DealScoutView.label() != ""
    assert is_binary(DealScoutView.icon()) and DealScoutView.icon() != ""
  end

  test "is cap-gated on the DealScoutRender render ActionSet" do
    assert DealScoutView.view_behavior() == Ezagent.ActionSet.DealScoutRender
  end

  test "declares an EXTERNAL json-render target" do
    assert DealScoutView.external_render?() == true
  end

  test "external_render produces the source_type-classified json-render tree" do
    tree = DealScoutView.external_render(Ezagent.URI.new!("session://system/default/t"))
    assert is_map(tree)
    assert tree.component == :dealscout_feed
    assert Enum.map(tree.groups, & &1.source_type) |> Enum.sort() == [:directed, :public]
  end

  test "applies_to? is fail-safe false for a session that is not a dealscout install" do
    refute DealScoutView.applies_to?(Ezagent.URI.new!("session://system/default/not-dealscout"))
    refute DealScoutView.applies_to?(:garbage)
  end

  test "is registered in the SessionViewRegistry at plugin boot" do
    assert :dealscout_feed in Ezagent.UI.SessionViewRegistry.all_ids()
    assert {:ok, EzagentPluginDealScout.DealScoutView} = Ezagent.UI.SessionViewRegistry.lookup(:dealscout_feed)
  end
end
