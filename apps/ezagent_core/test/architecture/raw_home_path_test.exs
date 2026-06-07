Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.RawHomePathTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "raw Home.path outside core does not grow beyond baseline" do
    assert_at_or_below(:raw_home_path_outside_core)
  end

  test "Path.expand(\"~\") call sites do not grow beyond baseline" do
    assert_at_or_below(:path_expand_home)
  end
end
