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
  import Ecto.Query

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
    # #201 PR-3 (R4) — immutable grant-incarnation id, minted at insert. The
    # ABA-safe identity for compensating deletes (`delete_incarnation/2`):
    # a hard-delete + reinsert resets `version` to 1, so URI+version cannot
    # distinguish two incarnations of a grant for the same agent.
    field(:incarnation_id, :string)
    # #201-cred (codex r2 HIGH-5) — the authority generations this grant was
    # authorized under (the cap-checked holder + the credential source). A
    # stale mint (authorized before an authority regenesis, inserted after) is
    # rejected at insertion and detectable at materialization. NULL = not
    # generation-guarded (workspace-shared mints, pre-column rows).
    field(:holder_generation, :integer)
    field(:source_generation, :integer)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Insert a new grant (id = agent_uri). Collides if an active grant exists.

  #201-cred (codex r2 HIGH-3) — the `incarnation_id` is minted
  UNCONDITIONALLY here: a caller-supplied id is ALWAYS overwritten, so no
  caller can reuse a previous incarnation's identity (which would weaken the
  ABA-safe compare in `delete_incarnation/2` and the materialize-time
  `(agent_uri, incarnation_id, version)` revalidation).

  TODO(path-b-hardening): #201-cred r3 HIGH-3 — this durable-grant WRITER is
  PUBLIC, so a caller can bypass `GrantMint.mint/3` (and its created-winner
  witness check) and insert a grant directly. The prod census shows only
  `GrantMint` calls it, so this is defense-in-depth against a FUTURE writer, not
  a live hole. Full close (deferred, same-BEAM Path B): confine minting so the
  durable insert is reachable ONLY from `GrantMint.mint/3` — e.g. a
  mint-scoped process-authorization token this insert checks — routing the ~9
  fixture call sites through one shared test seam. cc to file the tracking issue.
  """
  @spec insert(map()) :: {:ok, t()} | {:error, term()}
  def insert(attrs) do
    attrs = put_workspace_uri(attrs)

    %__MODULE__{}
    |> cast(
      attrs
      |> Map.put(:id, attrs.agent_uri)
      |> Map.put(:incarnation_id, Ecto.UUID.generate()),
      [
        :id,
        :agent_uri,
        :workspace_uri,
        :credential_source_uri,
        :approved_by,
        :approved_scope,
        :version,
        :incarnation_id,
        :holder_generation,
        :source_generation
      ]
    )
    |> validate_required([
      :id,
      :agent_uri,
      :workspace_uri,
      :credential_source_uri,
      :approved_by,
      :approved_scope,
      :incarnation_id
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

  @doc """
  #201 PR-3 (R4) — ABA-safe compensating HARD-delete: remove the grant row
  ONLY if it is still the exact incarnation the caller minted. The compare
  is transactional (a single `DELETE ... WHERE agent_uri = ? AND
  incarnation_id = ?`), so a stale compensator racing a hard-delete +
  reinsert (or a `reapprove/1`, which also re-incarnates) can never delete
  a DIFFERENT incarnation's row — with `delete/1` that race wipes the new
  owner's grant (URI key reused, `version` reset to 1).

  Like `delete/1`, this frees the unique `agent_uri` key on success.
  Idempotent + fail-conservative: `{:ok, :no_grant}` when the row is
  absent OR present under a different incarnation (including legacy rows
  with a NULL `incarnation_id`, which never match).
  """
  @spec delete_incarnation(String.t(), String.t()) ::
          {:ok, :deleted | :no_grant} | {:error, term()}
  def delete_incarnation(agent_uri, incarnation_id)
      when is_binary(agent_uri) and is_binary(incarnation_id) do
    import Ecto.Query

    case Repo.delete_all(
           from(g in __MODULE__,
             where: g.agent_uri == ^agent_uri and g.incarnation_id == ^incarnation_id
           )
         ) do
      {1, _} -> {:ok, :deleted}
      {0, _} -> {:ok, :no_grant}
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
  Materialize-facing fetch (codex H3'): returns `{:ok, source_uri, version,
  incarnation_id}` ONLY for an active, non-revoked grant whose `approved_scope`
  still matches the source's identity, whose source still exists, AND whose
  recorded authority generations are still current; else `{:error, reason}`
  (`:revoked` | `:no_grant` | `:source_not_found` | `:scope_mismatch` |
  `:stale_authority_generation`). The returned `{version, incarnation_id}` is
  the ABA-safe identity to re-check immediately before exec
  (`revalidate_version!/3`) — #201-cred (codex r2 HIGH-4): URI+version alone
  cannot distinguish two incarnations (a hard-delete + reinsert resets
  `version` to 1; two racing reapprovals once computed the same next version).

  #201-cred (codex r2 HIGH-5) — a grant whose recorded holder/source
  authority generation is no longer current fails here with
  `:stale_authority_generation`: it was minted under an authority that has
  since regenerated, so materializing from it would use a stale
  authorization. Rows without recorded generations (workspace-shared mints,
  legacy rows) skip this check.
  """
  @spec fetch_for_materialize(String.t()) ::
          {:ok, String.t(), non_neg_integer(), String.t()}
          | {:error,
             :no_grant
             | :revoked
             | :scope_mismatch
             | :source_not_found
             | :stale_authority_generation}
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
          not generations_current?(g) -> {:error, :stale_authority_generation}
          true -> {:ok, g.credential_source_uri, g.version, g.incarnation_id}
        end
    end
  end

  @doc """
  TOCTOU re-check (codex H1' + #201-cred codex r2 HIGH-4): call immediately
  before subprocess exec / curl-slice write with the `{version,
  incarnation_id}` from `fetch_for_materialize/1`. Returns `:ok` iff the
  grant is still present, not revoked, still the exact incarnation the caller
  materialized from, AND its recorded holder/source authority generations are
  STILL current; else `{:error, :grant_changed}` — the caller MUST abort the
  start (do NOT launch with the now-stale secret). The incarnation compare
  closes the ABA hole URI+version left open (delete + reinsert at the same
  version, or two reapprovals racing one version number).

  #201-cred (codex r2 NEW-HIGH-2) — the generation re-check is the crux of
  this revalidation, not just a repeat of the incarnation compare: a holder
  or source `regenesis` to N+1 that lands AFTER `fetch_for_materialize/1`
  does NOT change the grant's incarnation or version, so an incarnation+version
  compare alone would pass and a secret authorized under the now-RETIRED
  authority N would still commit + launch. Re-running `generations_current?/1`
  here (and thus at BOTH the pre-commit and pre-launch boundaries, which route
  through this function) denies the stale start. The recorded generation on the
  row is the stable anchor: it never moves, so current-vs-recorded catches any
  post-fetch regenesis.

  #201-cred (codex r2 NEW-MEDIUM-4) — a legacy grant minted before the
  incarnation column existed carries `incarnation_id = nil`;
  `fetch_for_materialize/1` then hands a `nil` incarnation to this function.
  The `is_binary` guard on the primary clause would leave that unmatched and
  raise `FunctionClauseError` mid-materialization. The explicit `nil` clause
  below revalidates such a legacy row on `(version, not-revoked,
  generations-current)` alone — there is no incarnation to compare.
  """
  @spec revalidate_version!(String.t(), String.t() | nil, non_neg_integer()) ::
          :ok | {:error, :grant_changed}
  def revalidate_version!(agent_uri, incarnation_id, version)
      when is_binary(incarnation_id) do
    case get_for_agent(agent_uri) do
      %__MODULE__{revoked_at: nil, version: ^version, incarnation_id: ^incarnation_id} = g ->
        if generations_current?(g), do: :ok, else: {:error, :grant_changed}

      _ ->
        {:error, :grant_changed}
    end
  end

  def revalidate_version!(agent_uri, nil, version) when is_binary(agent_uri) do
    case get_for_agent(agent_uri) do
      %__MODULE__{revoked_at: nil, version: ^version, incarnation_id: nil} = g ->
        if generations_current?(g), do: :ok, else: {:error, :grant_changed}

      _ ->
        {:error, :grant_changed}
    end
  end

  @doc """
  Re-approve / replace a grant for an agent (e.g. after revoke, owner re-approves a
  source). Upsert by agent_uri, bumping version so any in-flight start re-validating the
  OLD version aborts. Cap-check the re-approval at the calling Behavior (same as insert).

  #201-cred (codex r2 HIGH-4) — the version advance is a SINGLE atomic
  statement (`INSERT ... ON CONFLICT DO UPDATE SET version =
  credential_grants.version + 1`): two concurrent reapprovals can no longer
  both read version N and both install version N+1 (which let a stale
  materializer's version-only revalidation pass against the WRONG source).
  Each reapproval also installs its own freshly minted `incarnation_id`, so
  the `(agent_uri, incarnation_id, version)` revalidation identifies exactly
  one logical grant.
  """
  @spec reapprove(map()) :: {:ok, t()} | {:error, term()}
  def reapprove(attrs) do
    attrs = put_workspace_uri(attrs)
    # A re-approval is a NEW logical grant: re-incarnate (so a stale #201
    # compensator holding the OLD incarnation id cannot delete this row, and a
    # stale materializer's revalidation fails). Minted client-side; the version
    # bump is atomic server-side (below).
    incarnation_id = Ecto.UUID.generate()

    %__MODULE__{}
    |> cast(
      Map.merge(attrs, %{
        id: attrs.agent_uri,
        version: 1,
        revoked_at: nil,
        incarnation_id: incarnation_id
      }),
      [
        :id,
        :agent_uri,
        :workspace_uri,
        :credential_source_uri,
        :approved_by,
        :approved_scope,
        :version,
        :revoked_at,
        :incarnation_id,
        :holder_generation,
        :source_generation
      ]
    )
    |> validate_required([
      :id,
      :agent_uri,
      :workspace_uri,
      :credential_source_uri,
      :approved_by,
      :approved_scope,
      :incarnation_id
    ])
    |> Repo.insert(
      on_conflict: [
        set: [
          workspace_uri: attrs.workspace_uri,
          credential_source_uri: attrs.credential_source_uri,
          approved_by: attrs.approved_by,
          approved_scope: attrs.approved_scope,
          revoked_at: nil,
          incarnation_id: incarnation_id,
          holder_generation: Map.get(attrs, :holder_generation),
          source_generation: Map.get(attrs, :source_generation),
          updated_at: DateTime.utc_now()
        ],
        # Atomic server-side version advance (`version = version + 1` in the
        # same INSERT ... ON CONFLICT statement): two concurrent reapprovals
        # get DISTINCT versions — the read-prev-then-upsert race is gone.
        inc: [version: 1]
      ],
      conflict_target: :id,
      # The atomically-advanced version is computed server-side; read it back
      # so the returned row carries the value the database actually stored.
      returning: true
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

  # #201-cred (codex r2 HIGH-5) — a generation-guarded grant is current only
  # while BOTH recorded authority generations (approving holder + credential
  # source) still match the CURRENT active authority rows. Fail-closed: an
  # unreadable authority row invalidates the grant. Rows without recorded
  # generations (workspace-shared mints, pre-column rows) skip the check.
  defp generations_current?(%__MODULE__{} = g) do
    generation_current?(g.approved_by, g.holder_generation) and
      generation_current?(g.credential_source_uri, g.source_generation)
  end

  defp generation_current?(_uri_str, nil), do: true

  defp generation_current?(uri_str, expected) do
    case Ezagent.Cap.Authority.current_generation(Ezagent.URI.new!(uri_str)) do
      {:ok, ^expected} -> true
      _ -> false
    end
  rescue
    _ -> false
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
