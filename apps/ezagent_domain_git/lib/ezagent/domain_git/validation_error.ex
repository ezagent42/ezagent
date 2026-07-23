defmodule Ezagent.DomainGit.ValidationError do
  @moduledoc "Closed validation errors for provider-neutral Git values."

  @type t ::
          :invalid_attributes
          | :invalid_file_change
          | :change_limit_exceeded
          | :unknown_fields
          | {:missing_field, atom()}
          | {:invalid_field, atom()}

  @doc "Validates atom-keyed attributes for exact fields before running value validation."
  @spec validate_attrs(term(), [atom()], (map() -> :ok | {:error, t()})) ::
          :ok | {:error, t()}
  def validate_attrs(attrs, fields, validate_values) when is_map(attrs) do
    keys = Map.keys(attrs)

    cond do
      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :invalid_attributes}

      Enum.any?(keys, &(&1 not in fields)) ->
        {:error, :unknown_fields}

      missing = Enum.find(fields, &(not Map.has_key?(attrs, &1))) ->
        {:error, {:missing_field, missing}}

      true ->
        validate_values.(attrs)
    end
  end

  def validate_attrs(_attrs, _fields, _validate_values), do: {:error, :invalid_attributes}

  @doc "Returns whether a value is a non-empty binary."
  @spec nonempty_string?(term()) :: boolean()
  def nonempty_string?(value), do: is_binary(value) and value != ""
end
