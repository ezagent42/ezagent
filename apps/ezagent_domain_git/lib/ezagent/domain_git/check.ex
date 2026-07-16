defmodule Ezagent.DomainGit.Check do
  @moduledoc "Normalized provider check facts."

  alias Ezagent.DomainGit.{ChangeRequest, ValidationError}
  @fields [:external_id, :name, :status, :conclusion, :url]
  @statuses [:queued, :in_progress, :completed]
  @conclusions [
    :succeeded,
    :failed,
    :cancelled,
    :skipped,
    :neutral,
    :timed_out,
    :action_required,
    :other
  ]
  @enforce_keys @fields
  defstruct @fields
  @type status :: :queued | :in_progress | :completed
  @type conclusion ::
          :succeeded
          | :failed
          | :cancelled
          | :skipped
          | :neutral
          | :timed_out
          | :action_required
          | :other
  @type t :: %__MODULE__{
          external_id: String.t(),
          name: String.t(),
          status: status(),
          conclusion: conclusion() | nil,
          url: URI.t() | nil
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
      name: ValidationError.nonempty_string?(attrs.name),
      status: attrs.status in @statuses,
      conclusion: valid_conclusion?(attrs.status, attrs.conclusion),
      url: is_nil(attrs.url) or ChangeRequest.web_uri?(attrs.url)
    ]

    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end

  defp valid_conclusion?(:completed, conclusion), do: conclusion in @conclusions
  defp valid_conclusion?(status, nil) when status in [:queued, :in_progress], do: true
  defp valid_conclusion?(_status, _conclusion), do: false
end
