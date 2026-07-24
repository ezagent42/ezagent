defmodule EzagentPluginGitWorkflow.WorkflowRun do
  @moduledoc """
  Durable workflow intent run — the canonical `accepted` record.

  No secret, provider-private, or lifecycle-result fields.
  Idempotency enforced by PostgreSQL unique constraint on
  (binding_id, binding_generation, external_task_id).
  State transitions use single-statement CAS.
  """

  @fields [
    :id,
    :binding_id,
    :binding_generation,
    :external_task_id,
    :authenticated_principal_uri,
    :status,
    :state_version,
    :input_digest,
    :source_task_uri,
    :source_revision,
    :requested_head_ref,
    :last_error_code
  ]

  @enforce_keys @fields
  defstruct @fields ++ [:inserted_at, :updated_at]

  @type t :: %__MODULE__{
          id: String.t(),
          binding_id: String.t(),
          binding_generation: pos_integer(),
          external_task_id: String.t(),
          authenticated_principal_uri: URI.t(),
          status: String.t(),
          state_version: pos_integer(),
          input_digest: String.t(),
          source_task_uri: URI.t(),
          source_revision: String.t() | nil,
          requested_head_ref: String.t() | nil,
          last_error_code: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Builds a validated WorkflowRun struct."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_known_fields(attrs),
         :ok <- validate_values(attrs) do
      struct = struct!(__MODULE__, Map.take(attrs, @fields))
      {:ok, struct}
    end
  end

  def new(_), do: {:error, :invalid_attributes}

  defp validate_known_fields(attrs) do
    extra = Map.keys(attrs) -- @fields

    if extra == [],
      do: :ok,
      else: {:error, {:unknown_fields, extra}}
  end

  defp validate_values(attrs) do
    checks = [
      {:id, is_binary(attrs.id) and byte_size(attrs.id) > 0},
      {:binding_id, is_binary(attrs.binding_id) and byte_size(attrs.binding_id) > 0},
      {:binding_generation, is_integer(attrs.binding_generation) and attrs.binding_generation > 0},
      {:external_task_id, is_binary(attrs.external_task_id) and byte_size(attrs.external_task_id) > 0},
      {:authenticated_principal_uri, is_struct(attrs.authenticated_principal_uri, URI)},
      {:status, attrs.status in ["accepted"]},
      {:state_version, is_integer(attrs.state_version) and attrs.state_version > 0},
      {:input_digest, is_binary(attrs.input_digest) and byte_size(attrs.input_digest) > 0},
      {:source_task_uri, is_struct(attrs.source_task_uri, URI)},
      {:source_revision, is_nil(attrs.source_revision) or
                         (is_binary(attrs.source_revision) and byte_size(attrs.source_revision) > 0)},
      {:requested_head_ref, is_nil(attrs.requested_head_ref) or
                            (is_binary(attrs.requested_head_ref) and byte_size(attrs.requested_head_ref) > 0)},
      {:last_error_code, is_nil(attrs.last_error_code) or
                         (is_binary(attrs.last_error_code) and byte_size(attrs.last_error_code) > 0)}
    ]

    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end
end
