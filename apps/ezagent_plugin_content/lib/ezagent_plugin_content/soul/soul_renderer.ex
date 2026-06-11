defmodule EzagentPluginContent.Soul.SoulRenderer do
  @moduledoc """
  Render {{key}} placeholders in soul templates using slot_values.
  Generate full CLAUDE.md for cc agent.
  """

  @key_pattern ~r/\{\{([a-z][a-z0-9_.-]*)\}\}/

  @doc """
  Render all templates with slot_values. Returns merged binary.
  Missing keys retain raw {{key}} as signal.
  """
  @spec render([binary()], map()) :: binary()
  def render(templates, slot_values) when is_list(templates) do
    merged = Enum.join(templates, "\n\n")

    Regex.replace(@key_pattern, merged, fn _, key ->
      resolve_key(key, slot_values)
    end)
  end

  @doc """
  Full CLAUDE.md: preamble + rendered soul + skill_index.
  """
  @spec full_claude_md([binary()], map(), binary()) :: binary()
  def full_claude_md(templates, slot_values, skill_index \\ "") do
    preamble = get_preamble()
    rendered = render(templates, slot_values)

    [preamble, rendered, skill_index]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  defp resolve_key(key, values) do
    parts = String.split(key, ".")

    case get_in(values, parts) do
      nil -> "{{#{key}}}"
      val when is_binary(val) -> val
      _ -> "{{#{key}}}"
    end
  end

  defp get_preamble do
    path = Path.join(:code.priv_dir(:ezagent_plugin_content), "skeleton/config/cc_preamble.md")
    if File.exists?(path), do: File.read!(path), else: ""
  end
end
