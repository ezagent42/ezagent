defmodule EzagentPluginContent.Soul.SoulSlotParser do
  @moduledoc """
  Parse `{{key}}` placeholders from soul templates, grouped by section.

  Keys use dotted path grammar: `[a-z][a-z0-9_.-]*`.
  Sections are `## SECTION_NAME` headings.
  """

  @key_pattern ~r/\{\{([a-z][a-z0-9_.-]*)\}\}/

  defmodule SlotSection do
    @moduledoc false
    defstruct [:section, :keys]
  end

  @doc """
  Parse a soul template and return sections with their slot keys.

  Returns list of `%SlotSection{section: "NAME", keys: ["key1", "key2"]}`.
  """
  @spec parse_slots(binary()) :: [%SlotSection{}]
  def parse_slots(template) when is_binary(template) do
    template
    |> String.split(~r/^## /m, trim: true)
    |> Enum.map(fn block ->
      [section_name | _] = String.split(block, "\n", parts: 2)
      section_name = String.trim(section_name)
      # Strip leading number+dot (e.g. "1. IDENTITY" -> "IDENTITY")
      section_name = String.replace(section_name, ~r/^\d+\.\s*/, "")

      keys =
        @key_pattern
        |> Regex.scan(block)
        |> Enum.map(fn [_, key] -> key end)
        |> Enum.uniq()

      %SlotSection{section: section_name, keys: keys}
    end)
  end
end
