defmodule EzagentPluginContent.SoulRenderer do
  @moduledoc "Render {{key}} templates against flattened slot values (v2 §3.2.2). Missing key → keep {{key}} literal."
  @slot_re ~r/\{\{\s*([A-Za-z0-9_.]+)\s*\}\}/

  @spec render([String.t()] | String.t(), map()) :: String.t()
  def render(layers, slot_values) when is_list(layers),
    do: layers |> Enum.map(&render(&1, slot_values)) |> Enum.join("\n\n")

  def render(template, slot_values) when is_binary(template) and is_map(slot_values) do
    Regex.replace(@slot_re, template, fn whole, key ->
      case Map.fetch(slot_values, key) do
        {:ok, v} -> to_string(v)
        :error -> whole
      end
    end)
  end

  @spec flatten(map()) :: map()
  def flatten(map, prefix \\ "") when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key = if prefix == "", do: to_string(k), else: "#{prefix}.#{k}"

      case v do
        %{} = nested -> Map.merge(acc, flatten(nested, key))
        _ -> Map.put(acc, key, v)
      end
    end)
  end
end
