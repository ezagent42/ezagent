defmodule Ezagent.DomainGit.CommitSha do
  @moduledoc "Normalized V1 SHA-1 commit identity."

  alias Ezagent.DomainGit.ValidationError
  @fields [:value]
  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{value: String.t()}

  @doc "Builds a commit identity and normalizes its SHA-1 value to lowercase."
  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, %__MODULE__{value: String.downcase(attrs.value)}}
    end
  end

  @doc "Returns whether a value is a 40-character hexadecimal SHA-1."
  @spec valid_sha1?(term()) :: boolean()
  def valid_sha1?(value) when is_binary(value) and byte_size(value) == 40,
    do: String.match?(value, ~r/\A[0-9A-Fa-f]{40}\z/)

  def valid_sha1?(_value), do: false

  defp validate_values(%{value: value}) do
    if valid_sha1?(value), do: :ok, else: {:error, {:invalid_field, :value}}
  end
end
