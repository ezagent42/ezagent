Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.OversizedModulesTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "oversized module LOC counters do not grow beyond baseline" do
    assert_at_or_below(:oversized_modules_gt_1500)
    assert_at_or_below(:oversized_modules_gt_1000)
  end

  test "god-function def-count proxies do not grow beyond baseline" do
    assert_at_or_below(:def_count_cc_agent)
    assert_at_or_below(:def_count_orchestrator_tools)
    assert_at_or_below(:def_count_session_creator)
    assert_at_or_below(:def_count_capability)
  end

  test "cc/codex duplicated Template Class LOC does not grow beyond baseline" do
    assert_at_or_below(:cc_codex_template_class_combined_loc)
  end
end
