defmodule Ezagent.Credential.GrantRow do
  @moduledoc """
  Durable credential GRANT (spec §5.1). One active grant per agent: who approved it,
  the exact source URI + scope it was approved for, and a monotonic `version` bumped
  on revoke. Read at every materialization (PR-2) to re-validate before exec.
  Pattern mirrors `Ezagent.ExternalMirror.BindingRow`.

  ## Source existence

  `fetch_for_materialize/1` checks the source still exists via the DURABLE snapshot
  store (`Ezagent.SnapshotStore.latest/1`), NOT `KindRegistry.lookup/1` — the latter
  only tracks currently-RUNNING pids, so a valid-but-cold source agent would falsely
  read as `:source_not_found`. The grant is a durable record validated against durable
  state.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "credential_grants" do
    field(:agent_uri, :string)
    field(:workspace_uri, :string)
    field(:credential_source_uri, :string)
    field(:approved_by, :string)
    field(:approved_scope, :string)
    field(:version, :integer, default: 1)
    field(:revoked_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Insert a new grant (id = agent_uri). Collides if an active grant exists."
  @spec insert(map()) :: {:ok, t()} | {:error, term()}
  def insert(attrs) do
    attrs = put_workspace_uri(attrs)

    %__MODULE__{}
    |> cast(
      Map.put(attrs, :id, attrs.agent_uri),
      [
        :id,
        :agent_uri,
        :workspace_uri,
        :credential_source_uri,
        :approved_by,
        :approved_scope,
        :version
      ]
    )
    |> validate_required([
      :id,
      :agent_uri,
      :workspace_uri,
      :credential_source_uri,
      :approved_by,
      :approved_scope
    ])
    |> unique_constraint(:agent_uri, name: :credential_grants_agent_uri_index)
    |> unique_constraint(:id, name: :credential_grants_pkey)
    |> Repo.insert()
  end

  @doc "The active grant for an agent, or nil."
  @spec get_for_agent(String.t()) :: t() | nil
  def get_for_agent(agent_uri), do: Repo.get(__MODULE__, agent_uri)

  @doc """
  HARD-delete the grant row for an agent (compensating cleanup). Distinct from
  `revoke/1` (soft — bumps version + stamps `revoked_at`, KEEPS the row): a
  delete frees the unique `agent_uri` key so a later retry's `insert/1` does not
  conflict. Used when a fresh agent spawn fails AFTER the grant was minted but
  BEFORE the agent came up (2026-06-07 file-flavor-create-cascade, codex r5) —
  the grant must leave NO orphaned row for an agent that never existed.
  Idempotent: `{:ok, :no_grant}` when absent.
  """
  @spec delete(String.t()) :: {:ok, t()} | {:ok, :no_grant} | {:error, term()}
  def delete(agent_uri) do
    case Repo.get(__MODULE__, agent_uri) do
      nil -> {:ok, :no_grant}
      row -> Repo.delete(row)
    end
  end

  @doc "Revoke: bump version, stamp revoked_at. Returns {:error, :no_grant} if absent."
  @spec revoke(String.t()) :: {:ok, t()} | {:error, term()}
  def revoke(agent_uri) do
    case Repo.get(__MODULE__, agent_uri) do
      nil ->
        {:error, :no_grant}

      row ->
        row
        |> change(version: row.version + 1, revoked_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  @doc "True iff the grant exists and is not revoked."
  @spec active?(String.t()) :: boolean()
  def active?(agent_uri) do
    case get_for_agent(agent_uri) do
      %__MODULE__{revoked_at: nil} -> true
      _ -> false
    end
  end

  @doc """
  Materialize-facing fetch (codex H3'): returns `{:ok, source_uri, version}` ONLY for an
  active, non-revoked grant whose `approved_scope` still matches the source's identity AND
  whose source still exists; else `{:error, reason}` (`:revoked` | `:no_grant` |
  `:source_not_found` | `:scope_mismatch`). The returned `version` is the value to
  re-check immediately before exec (`revalidate_version!/2`).
  """
  @spec fetch_for_materialize(String.t()) ::
          {:ok, String.t(), non_neg_integer()}
          | {:error, :no_grant | :revoked | :scope_mismatch | :source_not_found}
  def fetch_for_materialize(agent_uri) do
    case get_for_agent(agent_uri) do
      nil ->
        {:error, :no_grant}

      %__MODULE__{revoked_at: r} when not is_nil(r) ->
        {:error, :revoked}

      %__MODULE__{} = g ->
        cond do
          g.approved_scope != g.credential_source_uri -> {:error, :scope_mismatch}
          not source_exists?(g.credential_source_uri) -> {:error, :source_not_found}
          true -> {:ok, g.credential_source_uri, g.version}
        end
    end
  end

  @doc """
  TOCTOU re-check (codex H1'): call immediately before subprocess exec / curl-slice write
  with the `version` from `fetch_for_materialize/1`. Returns `:ok` iff the grant is still
  present, not revoked, AND its version is unchanged; else `{:error, :grant_changed}` —
  the caller MUST abort the start (do NOT launch with the now-stale secret).
  """
  @spec revalidate_version!(String.t(), non_neg_integer()) :: :ok | {:error, :grant_changed}
  def revalidate_version!(agent_uri, version) do
    case get_for_agent(agent_uri) do
      %__MODULE__{revoked_at: nil, version: ^version} -> :ok
      _ -> {:error, :grant_changed}
    end
  end

  @doc """
  Re-approve / replace a grant for an agent (e.g. after revoke, owner re-approves a
  source). Upsert by agent_uri, bumping version so any in-flight start re-validating the
  OLD version aborts. Cap-check the re-approval at the calling Behavior (same as insert).
  """
  @spec reapprove(map()) :: {:ok, t()} | {:error, term()}
  def reapprove(attrs) do
    attrs = put_workspace_uri(attrs)
    prev = get_for_agent(attrs.agent_uri)
    next_version = if prev, do: prev.version + 1, else: 1

    %__MODULE__{}
    |> cast(
      Map.merge(attrs, %{id: attrs.agent_uri, version: next_version, revoked_at: nil}),
      [
        :id,
        :agent_uri,
        :workspace_uri,
        :credential_source_uri,
        :approved_by,
        :approved_scope,
        :version,
        :revoked_at
      ]
    )
    |> validate_required([
      :id,
      :agent_uri,
      :workspace_uri,
      :credential_source_uri,
      :approved_by,
      :approved_scope
    ])
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :workspace_uri,
           :credential_source_uri,
           :approved_by,
           :approved_scope,
           :version,
           :revoked_at,
           :updated_at
         ]},
      conflict_target: :id
    )
  end

  # Durable existence: a source agent exists iff it has a persisted snapshot row.
  # Independent of whether the source Kind is currently running. Via the §2.2
  # actor read surface (C2): `read_durable/3` never spawns and answers durable
  # existence regardless of the probe slice key (`{:ok, _, _}` ⟺ the old
  # `match?({:ok, _}, SnapshotStore.latest/1)`).
  defp source_exists?(source_uri) do
    match?({:ok, _, _}, Ezagent.Kind.read_durable(source_uri, :identity))
  end

  defp put_workspace_uri(%{agent_uri: agent_uri} = attrs) do
    Map.put(attrs, :workspace_uri, workspace_uri_for!(agent_uri))
  end

  defp workspace_uri_for!(agent_uri) when is_binary(agent_uri) do
    agent_uri
    |> Ezagent.URI.new!()
    |> Ezagent.Capability.workspace_of()
    |> case do
      %URI{} = workspace_uri -> URI.to_string(workspace_uri)
      :any -> raise ArgumentError, "credential grant agent_uri must be workspace-scoped"
    end
  end
end
