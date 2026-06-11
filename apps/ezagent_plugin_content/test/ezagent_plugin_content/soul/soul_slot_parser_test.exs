defmodule EzagentPluginContent.Soul.SoulSlotParserTest do
  use ExUnit.Case
  alias EzagentPluginContent.Soul.SoulSlotParser

  doctest EzagentPluginContent.Soul.SoulSlotParser

  @template """
  ## 1. IDENTITY
  You ARE the {{identity.bot_full_name}}.

  ## 2. BRAND STRUCTURE
  {{identity.host_site_descriptor}} is operated by {{brand-structure.parent_company}}.
  HQ: {{brand-structure.parent_hq}}.

  ## 5. GATE
  Escalation triggers: {{gate.escalation_triggers}}
  Escalation phrase: {{gate.escalation_phrase}}
  """

  test "parse_slots extracts all {{key}} grouped by section" do
    result = SoulSlotParser.parse_slots(@template)

    # 3 sections found
    assert length(result) == 3

    # Section 1: IDENTITY
    identity = Enum.find(result, &(&1.section == "IDENTITY"))
    assert identity.keys == ["identity.bot_full_name"]

    # Section 2: BRAND STRUCTURE
    brand = Enum.find(result, &(&1.section == "BRAND STRUCTURE"))

    assert brand.keys == [
             "identity.host_site_descriptor",
             "brand-structure.parent_company",
             "brand-structure.parent_hq"
           ]

    # Section 3: GATE
    gate = Enum.find(result, &(&1.section == "GATE"))
    assert gate.keys == ["gate.escalation_triggers", "gate.escalation_phrase"]
  end

  test "template with no {{key}} returns empty keys" do
    result = SoulSlotParser.parse_slots("## SECTION\nJust text, no slots.")
    assert length(result) == 1
    assert hd(result).keys == []
  end

  test "invalid key patterns are ignored" do
    result = SoulSlotParser.parse_slots("## S\n{{valid.key}} {{INVALID}} {{123bad}}")
    assert hd(result).keys == ["valid.key"]
  end
end
