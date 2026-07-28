defmodule EzagentPluginGitWorkflow.WorkflowFacts do
  @moduledoc """
  Typed, provider-neutral facts accumulated for one workflow run (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §5.3).

  Every field but `id`/`run_id`/`workspace_uri` is optional — `nil` is a
  legal "not yet known" value, not an error. No field may hold a raw
  response body, header, token, or credential.

  `Store.upsert_facts/1` performs a full-row **replace** for a `run_id`:
  the underlying `INSERT ... ON CONFLICT (run_id) DO UPDATE SET` overwrites
  every non-key column with the caller's values — including columns the
  caller left `nil`. A caller must therefore always pass a **complete**
  snapshot of the facts it wants persisted, never a partial delta: a write
  that omits a fact set by an earlier write silently erases it, it does
  not merge with it. P1 has exactly one writer, so this is safe as built
  today. If a later slice (P2 workspace collection, P3 GitHub
  reconciliation, P4 observation ticks) introduces a second writer that
  needs to accumulate facts incrementally, that slice must design explicit
  merge or revision-CAS semantics at that point — it must not rely on
  partial upserts against this full-replace store (owner decision, Allen
  2026-07-26: the merge/CAS question is deferred to P2, when a real second
  writer exists to design against — see the P1 final-review fix report).

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
  @optional_string_fields [
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
    :checks_summary,
    :reviews_summary
  ]
  @optional_integer_fields [:checks_revision, :reviews_revision]
  @optional_datetime_fields [:checks_observed_at, :reviews_observed_at]
  @optional_fields @optional_string_fields ++
                     @optional_integer_fields ++ @optional_datetime_fields
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
          checks_summary: String.t() | nil,
          reviews_summary: String.t() | nil,
          checks_revision: integer() | nil,
          reviews_revision: integer() | nil,
          checks_observed_at: DateTime.t() | nil,
          reviews_observed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  The nullable fact columns — everything except the `id`/`run_id`/`workspace_uri`
  identity and the `inserted_at`/`updated_at` bookkeeping.

  `Store.update_facts/2` derives its column whitelist from this rather than
  re-typing the names: two hand-maintained copies of the same 16 names drift,
  and the copy that drifts is the one that silently stops guarding.
  """
  @spec optional_fields() :: [atom()]
  def optional_fields, do: @optional_fields

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
    id = Map.fetch!(attrs, :id)
    run_id = Map.fetch!(attrs, :run_id)
    workspace_uri = Map.fetch!(attrs, :workspace_uri)

    string_checks =
      Enum.map(@optional_string_fields, fn field ->
        {field, nil_or_non_empty_binary?(Map.get(attrs, field))}
      end)

    integer_checks =
      Enum.map(@optional_integer_fields, fn field ->
        {field, nil_or_non_negative_integer?(Map.get(attrs, field))}
      end)

    datetime_checks =
      Enum.map(@optional_datetime_fields, fn field ->
        {field, nil_or_datetime?(Map.get(attrs, field))}
      end)

    checks =
      [
        {:id, is_binary(id) and byte_size(id) > 0},
        {:run_id, is_binary(run_id) and byte_size(run_id) > 0},
        {:workspace_uri, is_struct(workspace_uri, URI) and Ezagent.URI.canonical?(workspace_uri)}
      ] ++ string_checks ++ integer_checks ++ datetime_checks

    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end

  defp nil_or_non_empty_binary?(nil), do: true
  defp nil_or_non_empty_binary?(v), do: is_binary(v) and byte_size(v) > 0

  defp nil_or_non_negative_integer?(nil), do: true
  defp nil_or_non_negative_integer?(v), do: is_integer(v) and v >= 0

  defp nil_or_datetime?(nil), do: true
  defp nil_or_datetime?(%DateTime{}), do: true
  defp nil_or_datetime?(_), do: false
end
