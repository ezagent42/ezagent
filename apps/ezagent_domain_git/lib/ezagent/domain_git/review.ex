defmodule Ezagent.DomainGit.Review do
  @moduledoc "A normalized submitted/latest review event."

  alias Ezagent.DomainGit.ValidationError
  @fields [:external_id, :author_label, :state, :submitted_at]
  @states [:approved, :changes_requested, :commented, :dismissed]
  @enforce_keys @fields
  defstruct @fields
  @type state :: :approved | :changes_requested | :commented | :dismissed
  @type t :: %__MODULE__{
          external_id: String.t(),
          author_label: String.t(),
          state: state(),
          submitted_at: DateTime.t() | nil
        }

  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp validate_values(attrs) do
    checks = [
      external_id: ValidationError.nonempty_string?(attrs.external_id),
      author_label: ValidationError.nonempty_string?(attrs.author_label),
      state: attrs.state in @states,
      submitted_at: is_nil(attrs.submitted_at) or match?(%DateTime{}, attrs.submitted_at)
    ]

    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end
end
