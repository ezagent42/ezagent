Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.EffectDisciplineTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "{:set, ...} effect surface is frozen and cross-slice violations stay zero" do
    assert_at_or_below(:set_effect_sites)
    assert_zero(:cross_slice_set_violations)
  end

  test ":all_slices escape hatch remains allowlisted only" do
    assert_at_or_below(:all_slices_occurrences)
    assert_zero(:all_slices_unsanctioned)
  end
end
