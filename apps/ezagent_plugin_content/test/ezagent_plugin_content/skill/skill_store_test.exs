defmodule EzagentPluginContent.Skill.SkillStoreTest do
  use ExUnit.Case
  alias EzagentPluginContent.Skill.SkillStore

  setup do
    tmp = Path.join(System.tmp_dir!(), "store_test_#{System.unique_integer()}")
    {:ok, tmp: tmp}
  end

  test "read returns content from highest priority layer", %{tmp: tmp} do
    # Write tenant lead
    SkillStore.write(tmp, "test-tenant", "customer", "lead", "# Tenant lead")
    # Write platform lead (same name, lower priority)
    plat_dir = Path.join([tmp, "platform", "skills", "lead"])
    File.mkdir_p!(plat_dir)
    File.write!(Path.join(plat_dir, "SKILL.md"), "# Platform lead")

    {:ok, content} = SkillStore.read(tmp, "test-tenant", "customer", "lead")
    assert content =~ "Tenant lead"
  end

  test "write creates skill file", %{tmp: tmp} do
    :ok = SkillStore.write(tmp, "test-tenant", "customer", "faq", "# FAQ")
    {:ok, content} = SkillStore.read(tmp, "test-tenant", "customer", "faq")
    assert content =~ "FAQ"
  end

  test "delete removes skill file", %{tmp: tmp} do
    SkillStore.write(tmp, "test-tenant", "customer", "temp", "# Temp")
    {:ok, _} = SkillStore.read(tmp, "test-tenant", "customer", "temp")
    :ok = SkillStore.delete(tmp, "test-tenant", "customer", "temp")
    assert SkillStore.read(tmp, "test-tenant", "customer", "temp") == :not_found
  end
end
