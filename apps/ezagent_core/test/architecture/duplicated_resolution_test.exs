Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.DuplicatedResolutionTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "resolve_template_class definitions do not grow beyond baseline" do
    assert_at_or_below(:duplicated_resolve_template_class)
  end
end
