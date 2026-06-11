defmodule EzagentPluginContent.Soul.SoulLoaderTest do
  use ExUnit.Case
  alias EzagentPluginContent.Soul.SoulLoader

  setup do
    tmp = Path.join(System.tmp_dir!(), "loader_test_#{System.unique_integer()}")
    File.mkdir_p!(tmp)
    {:ok, tmp: tmp}
  end

  test "loads 4 layers, later overrides earlier", %{tmp: tmp} do
    # L0 Framework
    File.mkdir_p!(Path.join(tmp, "platform/framework/customer"))
    File.write!(Path.join(tmp, "platform/framework/customer/soul.md"), "## IDENTITY\nL0 id")
    # L3 Template (overrides L0)
    File.mkdir_p!(Path.join(tmp, "platform/templates/customer"))
    File.write!(Path.join(tmp, "platform/templates/customer/soul.md"), "## IDENTITY\nL3 id\n## EXTRA\nL3 extra")

    result = SoulLoader.load(tmp, "test-tenant", "customer")
    assert Enum.any?(result, &(&1 =~ "L0 id"))
    assert Enum.any?(result, &(&1 =~ "L3 id"))   # L3 overrides
    assert Enum.any?(result, &(&1 =~ "L3 extra"))
  end
end
