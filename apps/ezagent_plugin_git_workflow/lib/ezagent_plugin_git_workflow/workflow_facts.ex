defmodule EzagentPluginGitWorkflow.WorkflowFacts do
  @moduledoc """
  Typed, provider-neutral facts accumulated for one workflow run (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §5.3).

  Every field but `id`/`run_id`/`workspace_uri` is populated incrementally
  by later slices (P2 workspace collection, P3 GitHub reconciliation, P4
  observation ticks) — nil is a legal "not yet known" value, not an error.
  No field may hold a raw response body, header, token, or credential.

  `workspace_uri` is required even though design §5.3's fact list does not
  name it: every per-tenant DB table in this codebase carries a
  `workspace_uri NOT NULL` column so reads can scope by workspace without a
  join — enforced repo-wide by
  `EzagentCore.Invariants.PerTenantTablesHaveWorkspaceColumnTest`'s
  "exemption discipline" gate, which enumerates every live DB table. The
  sibling `git_workflow_runs`/`git_workflow_bindings` tables in this same
  plugin already carry `workspace_uri` for the identical reason even
  though it is equally derivable there via `binding_id` — this struct
  follows that established precedent for its own `run_id`-keyed row.
  """

  @required_fields [:id, :run_id, :workspace_uri]
  @optional_fields [
    :workspace_provision_id,
    :deterministic_head_ref,
    :change_digest,
    :expected_base_sha,
    :head_sha,
    :change_request_id,
    :change_request_url,
    :change_request_state,
    :change_request_head_ref,
    :change_request_base_ref,
    :checks_revision,
    :checks_summary,
    :checks_observed_at,
    :reviews_revision,
    :reviews_summary,
    :reviews_observed_at
  ]
  @fields @required_fields ++ @optional_fields

  @enforce_keys @required_fields
  defstruct @fields ++ [:inserted_at, :updated_at]

  @type t :: %__MODULE__{
          id: String.t(),
          run_id: String.t(),
          workspace_uri: URI.t(),
          workspace_provision_id: String.t() | nil,
          deterministic_head_ref: String.t() | nil,
          change_digest: String.t() | nil,
          expected_base_sha: String.t() | nil,
          head_sha: String.t() | nil,
          change_request_id: String.t() | nil,
          change_request_url: String.t() | nil,
          change_request_state: String.t() | nil,
          change_request_head_ref: String.t() | nil,
          change_request_base_ref: String.t() | nil,
          checks_revision: integer() | nil,
          checks_summary: String.t() | nil,
          checks_observed_at: DateTime.t() | nil,
          reviews_revision: integer() | nil,
          reviews_summary: String.t() | nil,
          reviews_observed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Builds a validated WorkflowFacts record. Unknown fields are rejected."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs),
         :ok <- validate_known_fields(attrs),
         :ok <- validate_values(attrs) do
      {:ok, struct!(__MODULE__, Map.take(attrs, @fields))}
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}

  defp validate_required(attrs) do
    missing = Enum.filter(@required_fields, fn f -> not Map.has_key?(attrs, f) end)

    if missing == [],
      do: :ok,
      else: {:error, {:missing_field, hd(missing)}}
  end

  defp validate_known_fields(attrs) do
    extra = Map.keys(attrs) -- @fields

    if extra == [],
      do: :ok,
      else: {:error, {:unknown_fields, extra}}
  end

  defp validate_values(attrs) do
    workspace_uri = Map.fetch!(attrs, :workspace_uri)

    if is_struct(workspace_uri, URI) and Ezagent.URI.canonical?(workspace_uri),
      do: :ok,
      else: {:error, {:invalid_field, :workspace_uri}}
  end
end
