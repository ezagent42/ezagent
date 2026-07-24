defmodule EzagentPluginGitWorkflow.AcceptIntent do
  @moduledoc """
  Permission-neutral typed accept command — E2-A only.

  ONLY these caller-supplied fields are accepted:
    - binding_id, binding_generation, external_task_id
    - source_task_uri, source_revision, requested_head_ref

  Server-owned fields (id, status, state_version, input_digest,
  last_error_code) are REJECTED at construction — callers must NOT
  supply them. Missing fields return a stable error tuple, not KeyError.
  """

  @allowed_fields [
    :binding_id,
    :binding_generation,
    :external_task_id,
    :source_task_uri,
    :source_revision,
    :requested_head_ref
  ]

  @server_owned_fields ~w(id status state_version input_digest last_error_code)a

  @enforce_keys @allowed_fields
  defstruct @allowed_fields

  @type t :: %__MODULE__{
          binding_id: String.t(),
          binding_generation: pos_integer(),
          external_task_id: String.t(),
          source_task_uri: URI.t(),
          source_revision: String.t() | nil,
          requested_head_ref: String.t() | nil
        }

  @doc """
  Build a validated AcceptIntent. Rejects:
    - missing required fields
    - server-owned fields (atom keys only)
    - unknown extra fields
    - invalid values
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- reject_server_owned(attrs),
         :ok <- validate_required(attrs),
         :ok <- validate_no_extra(attrs),
         :ok <- validate_values(attrs) do
      {:ok, struct!(__MODULE__, Map.take(attrs, @allowed_fields))}
    end
  end

  def new(_), do: {:error, :invalid_attributes}

  defp reject_server_owned(attrs) do
    server_in = Enum.filter(Map.keys(attrs), &(is_atom(&1) and &1 in @server_owned_fields))

    case server_in do
      [offender | _] -> {:error, {:server_owned_field, offender}}
      [] -> :ok
    end
  end

  defp validate_required(attrs) do
    missing = Enum.filter(@allowed_fields, fn f -> not Map.has_key?(attrs, f) end)

    if missing == [],
      do: :ok,
      else: {:error, {:missing_field, hd(missing)}}
  end

  defp validate_no_extra(attrs) do
    extra =
      Map.keys(attrs)
      |> Enum.reject(&(&1 in @allowed_fields))
      |> Enum.reject(&(is_atom(&1) and &1 in @server_owned_fields))

    if extra == [],
      do: :ok,
      else: {:error, {:unknown_fields, extra}}
  end

  defp validate_values(attrs) do
    binding_id = Map.fetch!(attrs, :binding_id)
    binding_generation = Map.fetch!(attrs, :binding_generation)
    external_task_id = Map.fetch!(attrs, :external_task_id)
    source_task_uri = Map.fetch!(attrs, :source_task_uri)
    source_revision = Map.fetch!(attrs, :source_revision)
    requested_head_ref = Map.fetch!(attrs, :requested_head_ref)

    checks = [
      {:binding_id, is_binary(binding_id) and byte_size(binding_id) > 0},
      {:binding_generation, is_integer(binding_generation) and binding_generation > 0},
      {:external_task_id, is_binary(external_task_id) and byte_size(external_task_id) > 0},
      {:source_task_uri, is_struct(source_task_uri, URI)},
      {:source_revision, is_nil(source_revision) or (is_binary(source_revision) and byte_size(source_revision) > 0)},
      {:requested_head_ref, is_nil(requested_head_ref) or (is_binary(requested_head_ref) and byte_size(requested_head_ref) > 0)}
    ]

    case Enum.find(checks, fn {_f, ok?} -> not ok? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end
end
