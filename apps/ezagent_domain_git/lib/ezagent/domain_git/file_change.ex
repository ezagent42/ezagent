defmodule Ezagent.DomainGit.FileChange do
  @moduledoc "A captured UTF-8 regular-file upsert."

  alias Ezagent.DomainGit.{ChangeLimits, ValidationError}
  @fields [:path, :operation, :content]
  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{path: String.t(), operation: :upsert, content: String.t()}

  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @spec validate_many(term()) ::
          :ok
          | {:error,
             :invalid_file_change | :change_limit_exceeded | :invalid_change_limits_config}
  def validate_many(changes) when is_list(changes) and changes != [] do
    with true <- Enum.all?(changes, &valid_struct?/1),
         {:ok, limits} <- ChangeLimits.current() do
      if length(changes) <= limits.max_files and
           Enum.all?(changes, &(byte_size(&1.content) <= limits.max_file_bytes)) and
           Enum.sum(Enum.map(changes, &byte_size(&1.content))) <= limits.max_total_bytes do
        :ok
      else
        {:error, :change_limit_exceeded}
      end
    else
      false -> {:error, :invalid_file_change}
      {:error, :invalid_change_limits_config} = error -> error
    end
  end

  def validate_many(_changes), do: {:error, :invalid_file_change}

  defp valid_struct?(%__MODULE__{} = change) do
    case new(Map.from_struct(change)) do
      {:ok, _validated} -> true
      {:error, _reason} -> false
    end
  end

  defp valid_struct?(_change), do: false

  defp validate_values(attrs) do
    cond do
      not valid_path?(attrs.path) ->
        {:error, {:invalid_field, :path}}

      attrs.operation != :upsert ->
        {:error, {:invalid_field, :operation}}

      not (is_binary(attrs.content) and String.valid?(attrs.content)) ->
        {:error, {:invalid_field, :content}}

      true ->
        :ok
    end
  end

  defp valid_path?(path) when is_binary(path) and path != "" do
    String.valid?(path) and not control_byte?(path) and
      not String.starts_with?(path, ["/", "\\"]) and not String.contains?(path, "\\") and
      segments_valid?(String.split(path, "/"))
  end

  defp valid_path?(_path), do: false

  defp segments_valid?(segments),
    do: Enum.all?(segments, &(&1 not in ["", ".", "..", ".git"]))

  defp control_byte?(value),
    do: value |> :binary.bin_to_list() |> Enum.any?(&(&1 < 32 or &1 == 127))
end
