defmodule EzagentPluginContent.YamlWriter do
  @moduledoc "Simple map-to-YAML-string encoder."

  def write(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> "#{k}: #{format_value(v)}" end)
    |> Enum.join("\n")
  end

  defp format_value(v) when is_binary(v) do
    # Escape special YAML characters in strings
    if String.contains?(v, ": ") or String.contains?(v, "#") or
       String.contains?(v, "\n") or String.contains?(v, "'") or
       String.starts_with?(v, " ") or String.ends_with?(v, " ") do
      "\"#{String.replace(v, "\"", "\\\"")}\""
    else
      "\"#{v}\""
    end
  end
  defp format_value(v) when is_integer(v), do: "#{v}"
  defp format_value(v) when is_float(v), do: "#{v}"
  defp format_value(v) when is_boolean(v), do: "#{v}"
  defp format_value(v), do: "\"#{v}\""
end
