defmodule Ezagent.Session.Config.Validation do
  @moduledoc false

  alias Ezagent.Session.Config.Operation

  @authority_keys MapSet.new(~w(
    caller principal authenticated_principal entity_uri owner owner_uri
    session session_uri workspace workspace_uri parent parent_template_uri caps
  ))

  @spec coerce(Operation.t(), map()) ::
          {:ok, map()} | {:error, {:invalid_args, list()} | {:missing_arg, String.t()}}
  @doc false
  def coerce(%Operation{input_schema: schema}, args) when is_map(args) do
    properties = Map.get(schema, "properties", %{})

    {coerced, violations} =
      args
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.reduce({%{}, []}, fn {key, value}, {values, errors} ->
        wire_key = to_string(key)

        cond do
          MapSet.member?(@authority_keys, wire_key) ->
            {values, [{:authority_context_forbidden, wire_key} | errors]}

          not Map.has_key?(properties, wire_key) ->
            {values, [{:unknown_arg, wire_key} | errors]}

          true ->
            expected = Map.fetch!(properties, wire_key)

            case coerce_value(value, expected) do
              {:ok, coerced_value} ->
                {Map.put(values, wire_key, coerced_value), errors}

              :error ->
                error = {:invalid_type, wire_key, expected_type(expected)}
                {values, [error | errors]}
            end
        end
      end)

    case Enum.reverse(violations) do
      [] -> required_result(coerced, Map.get(schema, "required", []))
      errors -> {:error, {:invalid_args, errors}}
    end
  end

  defp required_result(coerced, required) do
    Enum.find(required, fn key ->
      case Map.fetch(coerced, key) do
        {:ok, value} -> value in [nil, ""]
        :error -> true
      end
    end)
    |> case do
      nil -> {:ok, coerced}
      key -> {:error, {:missing_arg, key}}
    end
  end

  defp coerce_value(value, %{"type" => "string"}) when is_binary(value), do: {:ok, value}
  defp coerce_value(value, %{"type" => "integer"}) when is_integer(value), do: {:ok, value}

  defp coerce_value(value, %{"type" => "integer"}) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp coerce_value(value, %{"type" => "boolean"}) when is_boolean(value), do: {:ok, value}
  defp coerce_value("true", %{"type" => "boolean"}), do: {:ok, true}
  defp coerce_value("false", %{"type" => "boolean"}), do: {:ok, false}
  defp coerce_value(value, %{"type" => "object"}) when is_map(value), do: {:ok, value}

  defp coerce_value(value, %{"type" => "array", "items" => item_schema}) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, coerced} ->
      case coerce_value(item, item_schema) do
        {:ok, coerced_item} -> {:cont, {:ok, [coerced_item | coerced]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, coerced} -> {:ok, Enum.reverse(coerced)}
      :error -> :error
    end
  end

  defp coerce_value(value, schema) when not is_map_key(schema, "type"), do: {:ok, value}
  defp coerce_value(_value, _schema), do: :error

  defp expected_type(%{"type" => "array", "items" => item_schema}) do
    "array[#{expected_type(item_schema)}]"
  end

  defp expected_type(%{"type" => type}) when is_binary(type), do: type
  defp expected_type(_schema), do: "declared schema"
end
