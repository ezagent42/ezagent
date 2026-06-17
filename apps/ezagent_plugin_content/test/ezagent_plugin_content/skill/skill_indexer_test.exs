defmodule EzagentPluginContent.Skill.SkillIndexerTest do
  use ExUnit.Case
  alias EzagentPluginContent.Skill.SkillIndexer

  setup do
    tmp = Path.join(System.tmp_dir!(), "idx_test_#{System.unique_integer()}")
    tenant = Path.join([tmp, "tenants", "test-tenant", "sandbox", "skills", "customer", "lead"])
    File.mkdir_p!(tenant)

    File.write!(
      Path.join(tenant, "SKILL.md"),
      "---\nname: Lead Collection\ndescription: Collect lead info\n---\n# Lead"
    )

    # Canonical skeleton layout: platform/skills/<role>/<name>/SKILL.md.
    fw = Path.join([tmp, "platform", "skills", "customer", "greeting"])
    File.mkdir_p!(fw)
    File.write!(Path.join(fw, "SKILL.md"), "---\nname: Customer Greeting\n---\n# Greeting")
    {:ok, tmp: tmp}
  end

  test "build generates Skill Index markdown", %{tmp: tmp} do
    result = SkillIndexer.build(tmp, "test-tenant", "customer")
    assert result =~ "## Skill Index"
    assert result =~ "Lead Collection"
    assert result =~ "lead/SKILL.md"
    assert result =~ "Collect lead info"
    assert result =~ "Customer Greeting"
  end

  test "same-name skill uses highest priority", %{tmp: tmp} do
    # tenant lead overrides any platform lead
    result = SkillIndexer.build(tmp, "test-tenant", "customer")
    # tenant version
    assert result =~ "Lead Collection"
  end

  test "empty dirs produce empty index" do
    empty = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer()}")
    File.mkdir_p!(empty)
    assert SkillIndexer.build(empty, "no-tenant", "customer") == ""
  end
end
