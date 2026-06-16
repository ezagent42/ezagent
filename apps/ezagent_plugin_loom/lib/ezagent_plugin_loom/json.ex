defmodule EzagentPluginLoom.Json do
  @moduledoc """
  从 LLM 回复里抽第一个完整 JSON 对象(LLM 常用 ```json 包裹或夹带文字)。
  orchestrator / intent 等共用。
  """

  @spec extract_object(String.t()) :: {:ok, map()} | {:error, :no_json_object}
  def extract_object(text) when is_binary(text) do
    text = String.trim(text)
    candidate = if String.starts_with?(text, "{"), do: text, else: slice_first_object(text)

    case candidate && Jason.decode(candidate) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :no_json_object}
    end
  end

  defp slice_first_object(text) do
    case :binary.match(text, "{") do
      {start, _} ->
        case :binary.matches(text, "}") do
          [] ->
            nil

          matches ->
            {last, _} = List.last(matches)
            binary_part(text, start, last - start + 1)
        end

      :nomatch ->
        nil
    end
  end
end
