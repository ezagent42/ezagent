defmodule Ezagent.DomainGit.ChangeRequestId do
  @moduledoc "Provider-neutral external change-request identity."

  alias Ezagent.DomainGit.ValidationError
  @fields [:external_id]
  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{external_id: String.t()}

  @doc "Builds a provider-neutral identity from a non-empty external identifier."
  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp validate_values(attrs) do
    if ValidationError.nonempty_string?(attrs.external_id),
      do: :ok,
      else: {:error, {:invalid_field, :external_id}}
  end
end
