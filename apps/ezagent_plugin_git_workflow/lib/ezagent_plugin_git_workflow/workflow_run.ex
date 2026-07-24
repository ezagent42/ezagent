defmodule EzagentPluginGitWorkflow.WorkflowRun do
  @moduledoc """
  Durable workflow intent run — server-generated identity and digest.

  Server-owned fields (caller MUST NOT supply):
    - id        — deterministic hash of unique key
    - status    — always "accepted" on creation
    - state_version — always 1 on creation
    - input_digest  — content hash of intent fields

  Caller-supplied fields:
    - binding_id, binding_generation, external_task_id (unique key)
    - source_task_uri, source_revision, requested_head_ref (intent)

  No secret, provider-private, lifecycle-result, or authenticated_principal
  fields. Authorization is deferred to E2-B.
  """

  @caller_fields [
    :binding_id,
    :binding_generation,
    :external_task_id,
    :source_task_uri,
    :source_revision,
    :requested_head_ref
  ]

  @server_fields [
    :id,
    :status,
    :state_version,
    :input_digest,
    :last_error_code
  ]

  @all_fields @caller_fields ++ @server_fields

  @enforce_keys @all_fields
  defstruct @all_fields ++ [:inserted_at, :updated_at]

  @type t :: %__MODULE__{
          id: String.t(),
          binding_id: String.t(),
          binding_generation: pos_integer(),
          external_task_id: String.t(),
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

  @doc "The fields a caller is allowed to supply."
  def caller_fields, do: @caller_fields

  @doc """
  Builds a validated WorkflowRun struct from a complete field map.
  Used internally by Store after server-generating id/digest/status/version.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_known_fields(attrs),
         :ok <- validate_values(attrs) do
      struct = struct!(__MODULE__, Map.take(attrs, @all_fields))
      {:ok, struct}
    end
  end

  def new(_), do: {:error, :invalid_attributes}

  @doc """
  Generate a deterministic run id from the unique key.
  """
  @spec generate_id(String.t(), pos_integer(), String.t()) :: String.t()
  def generate_id(binding_id, binding_generation, external_task_id) do
    content = "#{binding_id}:#{binding_generation}:#{external_task_id}"

    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> then(&"run_#{String.slice(&1, 0, 16)}")
  end

  @doc """
  Compute input_digest from the intent fields.
  """
  @spec compute_digest(map()) :: String.t()
  def compute_digest(fields) when is_map(fields) do
    content =
      fields
      |> Map.take([:binding_id, :binding_generation, :external_task_id,
                    :source_task_uri, :source_revision, :requested_head_ref])
      |> then(fn m ->
        %{
          binding_id: m.binding_id,
          binding_generation: m.binding_generation,
          external_task_id: m.external_task_id,
          source_task_uri: to_string(m.source_task_uri),
          source_revision: m.source_revision,
          requested_head_ref: m.requested_head_ref
        }
      end)
      |> :erlang.term_to_binary([:deterministic])

    "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end

  defp validate_known_fields(attrs) do
    extra = Map.keys(attrs) -- @all_fields

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
