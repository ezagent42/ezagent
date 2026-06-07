Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.RuntimeOrderingTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "mutating actions keep a cap-check gate" do
    assert_zero(:missing_cap_check_mutating_actions)
  end

  test "Kind.Runtime authorization order and no-reentry gates stay intact" do
    assert_zero(:kind_runtime_ordering_violations)
    assert_zero(:kind_runtime_reentry_violations)
  end
end
