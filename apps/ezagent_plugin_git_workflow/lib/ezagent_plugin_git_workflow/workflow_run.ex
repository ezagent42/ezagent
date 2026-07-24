defmodule EzagentPluginGitWorkflow.WorkflowRun do
  @moduledoc """
  Durable workflow intent run — server-generated identity and digest.

  Server-owned / server-derived fields (caller MUST NOT supply):
    - id            — full sha256 digest of unique key
    - workspace_uri — derived from validated TaskBinding.workspace_uri
    - status        — always "accepted" on creation
    - state_version — always 1 on creation
    - input_digest  — content hash of intent fields

  Caller supplies via AcceptIntent:
    - binding_id, binding_generation, external_task_id (unique key)
    - source_task_uri, source_revision, requested_head_ref (intent)

  All URI fields are canonical Ezagent URIs (Ezagent.URI.canonical?/1).

  Closed status set (E2-A):
    accepted → workspace_ready → worker_ready → authority_ready
    → pr_open → checks_passed → awaiting_external_merge
    → merged_confirmed → projected → completed

  Control states: blocked | failed | cancelled

  Terminal states (reject further transitions):
    completed, failed, cancelled
  """

  # ── status vocabulary ────────────────────────────────────────

  @success_path ~w(
    accepted workspace_ready worker_ready authority_ready
    pr_open checks_passed awaiting_external_merge
    merged_confirmed projected completed
  )

  @control_states ~w(blocked failed cancelled)

  @all_statuses @success_path ++ @control_states

  @terminal_statuses ~w(completed failed cancelled)

  @doc "All valid workflow statuses."
  def statuses, do: @all_statuses

  @doc "Valid status?"
  @spec valid_status?(String.t()) :: boolean()
  def valid_status?(s), do: s in @all_statuses

  @doc "Terminal status?"
  @spec terminal?(String.t()) :: boolean()
  def terminal?(s), do: s in @terminal_statuses

  @doc "Initial status on accept."
  def initial_status, do: "accepted"

  # ── fields ────────────────────────────────────────────────────

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
    :workspace_uri,
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
          workspace_uri: URI.t(),
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

  # ── construction ──────────────────────────────────────────────

  @doc "The fields a caller is allowed to supply."
  def caller_fields, do: @caller_fields

  @doc """
  Build a validated WorkflowRun struct from a complete field map.
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
  Generate a full collision-resistant run id from the unique key.
  Uses sha256 — no truncation.
  """
  @spec generate_id(String.t(), pos_integer(), String.t()) :: String.t()
  def generate_id(binding_id, binding_generation, external_task_id) do
    content = "#{binding_id}:#{binding_generation}:#{external_task_id}"

    "run_" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end

  @doc "Compute input_digest from intent fields."
  @spec compute_digest(map()) :: String.t()
  def compute_digest(fields) when is_map(fields) do
    content =
      fields
      |> Map.take([
        :binding_id,
        :binding_generation,
        :external_task_id,
        :source_task_uri,
        :source_revision,
        :requested_head_ref
      ])
      |> then(fn m ->
        %{
          binding_id: Map.fetch!(m, :binding_id),
          binding_generation: Map.fetch!(m, :binding_generation),
          external_task_id: Map.fetch!(m, :external_task_id),
          source_task_uri: to_string(Map.fetch!(m, :source_task_uri)),
          source_revision: Map.fetch!(m, :source_revision),
          requested_head_ref: Map.fetch!(m, :requested_head_ref)
        }
      end)
      |> :erlang.term_to_binary([:deterministic])

    "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end

  # ── private validation ────────────────────────────────────────

  defp validate_known_fields(attrs) do
    extra = Map.keys(attrs) -- @all_fields

    if extra == [],
      do: :ok,
      else: {:error, {:unknown_fields, extra}}
  end

  defp validate_values(attrs) do
    id = Map.fetch!(attrs, :id)
    binding_id = Map.fetch!(attrs, :binding_id)
    binding_generation = Map.fetch!(attrs, :binding_generation)
    external_task_id = Map.fetch!(attrs, :external_task_id)
    status = Map.fetch!(attrs, :status)
    state_version = Map.fetch!(attrs, :state_version)
    input_digest = Map.fetch!(attrs, :input_digest)
    source_task_uri = Map.fetch!(attrs, :source_task_uri)
    source_revision = Map.fetch!(attrs, :source_revision)
    requested_head_ref = Map.fetch!(attrs, :requested_head_ref)
    workspace_uri = Map.fetch!(attrs, :workspace_uri)
    last_error_code = Map.fetch!(attrs, :last_error_code)

    checks = [
      {:id, is_binary(id) and byte_size(id) > 0},
      {:binding_id, is_binary(binding_id) and byte_size(binding_id) > 0},
      {:binding_generation, is_integer(binding_generation) and binding_generation > 0},
      {:external_task_id, is_binary(external_task_id) and byte_size(external_task_id) > 0},
      {:workspace_uri, is_struct(workspace_uri, URI) and Ezagent.URI.canonical?(workspace_uri)},
      {:status, valid_status?(status)},
      {:state_version, is_integer(state_version) and state_version > 0},
      {:input_digest, is_binary(input_digest) and byte_size(input_digest) > 0},
      {:source_task_uri,
       is_struct(source_task_uri, URI) and Ezagent.URI.canonical?(source_task_uri)},
      {:source_revision,
       is_nil(source_revision) or
         (is_binary(source_revision) and byte_size(source_revision) > 0)},
      {:requested_head_ref,
       is_nil(requested_head_ref) or
         (is_binary(requested_head_ref) and byte_size(requested_head_ref) > 0)},
      {:last_error_code,
       is_nil(last_error_code) or
         (is_binary(last_error_code) and byte_size(last_error_code) > 0)}
    ]

    case Enum.find(checks, fn {_f, ok?} -> not ok? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end
end
