defmodule EzagentPluginContent.Soul.SoulRendererTest do
  use ExUnit.Case
  alias EzagentPluginContent.Soul.SoulRenderer

  test "render replaces {{key}} with values" do
    template = ["## IDENTITY\nYou ARE the {{identity.bot_full_name}}."]
    values = %{"identity" => %{"bot_full_name" => "TestBot"}}
    result = SoulRenderer.render(template, values)
    assert result =~ "You ARE the TestBot."
  end

  test "missing key retains raw {{key}}" do
    template = ["## IDENTITY\nHello {{identity.unknown_key}}"]
    result = SoulRenderer.render(template, %{})
    assert result =~ "Hello {{identity.unknown_key}}"
  end

  test "nested key resolution" do
    template = ["## BRAND\nParent: {{brand-structure.parent_company}}"]
    values = %{"brand-structure" => %{"parent_company" => "ACME Inc"}}
    result = SoulRenderer.render(template, values)
    assert result =~ "Parent: ACME Inc"
  end

  test "full_claude_md combines preamble + rendered soul + skill_index" do
    # Requires soul_loader + slot_values; tests integration
    template = ["## SECTION\nKey: {{test.key}}"]
    values = %{"test" => %{"key" => "val"}}
    # Call with placeholder skill_index
    result = SoulRenderer.full_claude_md(template, values, "## Skill Index\n- test skill")
    assert result =~ "Key: val"
    assert result =~ "## Skill Index"
  end
end
