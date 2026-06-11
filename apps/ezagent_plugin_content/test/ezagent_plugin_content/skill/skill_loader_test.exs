defmodule EzagentPluginContent.Skill.SkillLoaderTest do
  use ExUnit.Case
  alias EzagentPluginContent.Skill.SkillLoader

  setup do
    tmp = Path.join(System.tmp_dir!(), "skill_test_#{System.unique_integer()}")
    # Tenant skill (highest priority)
    tenant = Path.join([tmp, "tenants", "test-tenant", "sandbox", "skills", "customer", "lead"])
    File.mkdir_p!(tenant)
    File.write!(Path.join(tenant, "SKILL.md"), "# Tenant lead")
    # Platform skill (same name, lower priority)
    plat = Path.join([tmp, "platform", "skills", "lead"])
    File.mkdir_p!(plat)
    File.write!(Path.join(plat, "SKILL.md"), "# Platform lead")
    # Framework skill (different name)
    fw = Path.join([tmp, "platform", "skills", "greeting"])
    File.mkdir_p!(fw)
    File.write!(Path.join(fw, "SKILL.md"), "# Framework greeting")
    {:ok, tmp: tmp}
  end

  test "list tenant layer returns tenant skills", %{tmp: tmp} do
    result = SkillLoader.list(tmp, "test-tenant", "customer", :tenant)
    assert length(result) == 1
    assert hd(result).name == "lead"
    assert hd(result).layer == :tenant
  end

  test "list platform layer", %{tmp: tmp} do
    result = SkillLoader.list(tmp, "test-tenant", "customer", :platform)
    # platform and framework share the same dir, so both lead and greeting appear
    assert length(result) == 2
    names = Enum.map(result, & &1.name)
    assert "lead" in names
    assert hd(Enum.filter(result, &(&1.name == "lead"))).layer == :platform
  end

  test "list framework layer", %{tmp: tmp} do
    result = SkillLoader.list(tmp, "test-tenant", "customer", :framework)
    # platform and framework share the same dir; both lead and greeting appear
    assert length(result) == 2
    names = Enum.map(result, & &1.name)
    assert "greeting" in names
    assert hd(Enum.filter(result, &(&1.name == "greeting"))).layer == :framework
  end
end
