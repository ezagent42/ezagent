defmodule Ezagent.TemplateTags do
  @moduledoc """
  TemplateTags — the SessionTemplate tag registry (Phase 7 completion
  SPEC §1.7 (c)).

  A **tag** is a mutable, git-style ref onto a SessionTemplate version.
  A SessionTemplate version is content-addressed and immutable — its
  `kind_snapshots` row is keyed by `template://session/<ws>/<name>@<hash>`
  and never edited in place (`Ezagent.ActionSet.Template` `:write` is
  write-once + hash-checked, PR-1). A tag like `stable` or `v1.0` is the
  mutable layer on top: it can be re-pointed at any existing hash for
  the same `(workspace, name)`, exactly like a git branch/tag moves
  while commits do not.

  ## Source of truth + read cache — the `Ezagent.Routing.RuleStore` pattern

  `Ezagent.TemplateTags` follows `Ezagent.Routing.RuleStore` exactly:

  - the **`template_tags` Postgres table is the source of truth** — every
    mutation (`put/5`, `move/5`) writes there first, and CAS
    correctness rides on the DB's atomic `UPDATE ... WHERE`;
  - an **ETS table is the runtime read cache** — `resolve/3` and
    `list/1` read it for O(1) lock-free lookups. The cache is hydrated
    from the DB at boot via `load_into_registry/0` and kept in sync by
    every successful mutation.

  The ETS table `:ezagent_template_tags` is created by
  `EzagentCore.EtsOwner` (a child of `EzagentCore.Application`'s
  supervisor, started before anything that touches it).

  ## Key — `(workspace_uri, name, tag)`

  A tag is scoped to a `(workspace, template-name)` pair. The
  `workspace_uri` is part of the key — a `stable` tag in workspace A
  and a `stable` tag in workspace B are **DISTINCT rows** and never
  resolve to each other (SPEC §1.2 cross-workspace non-collision;
  codex rev-2 CRITICAL). The DB enforces this with a
  `UNIQUE (workspace_uri, name, tag)` index.

  ## CAS `move/5`

  `move/5` is a compare-and-swap: it re-points a tag onto `new_hash`
  **only if** the row currently points at `expected_hash`. It is
  implemented as a single atomic SQL `UPDATE ... WHERE version_hash =
  ?expected` — so when N callers race to move the same tag, exactly one
  `UPDATE` matches the row and the rest match zero rows. The winner
  gets `:ok`; every loser gets `{:error, :tag_moved}`. No row lock, no
  `Repo.transaction` needed — the WHERE clause IS the CAS.

  ## API

  - `put(workspace, name, tag, version_hash, created_by)` —
    insert-or-overwrite the `(workspace, name, tag) → version_hash`
    mapping. Unconditional (use `move/5` for conditional re-point).
  - `resolve(workspace, name, tag) :: {:ok, hash} | :error`
  - `list(workspace) :: [t()]` — every tag row in the workspace.
  - `move(workspace, name, tag, expected_hash, new_hash) ::
    :ok | {:error, :tag_moved} | {:error, :no_such_tag}` — CAS.
  - `load_into_registry/0` — boot-time ETS hydration from the DB.
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @table :ezagent_template_tags

  @primary_key {:id, :id, autogenerate: true}
  schema "template_tags" do
    field :workspace_uri, :string
    field :name, :string
    field :tag, :string
    field :version_hash, :string
    field :created_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          workspace_uri: String.t(),
          name: String.t(),
          tag: String.t(),
          version_hash: String.t(),
          created_by: String.t() | nil
        }

  @doc """
  The ETS read-cache table name. `EzagentCore.EtsOwner` creates it.
  """
  def table, do: @table

  # --- put ---------------------------------------------------------------

  @doc """
  Insert or overwrite the `(workspace, name, tag) → version_hash`
  mapping.

  Unconditional — if the tag already exists it is overwritten with the
  new hash regardless of its prior value. Use `move/5` for a
  conditional (compare-and-swap) re-point.

  Returns `:ok`.
  """
  @spec put(
          URI.t() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          URI.t() | String.t() | nil
        ) :: :ok | {:error, term()}
  def put(workspace, name, tag, version_hash, created_by)
      when is_binary(name) and is_binary(tag) and is_binary(version_hash) do
    ws = uri_to_str(workspace)
    by = uri_to_str_or_nil(created_by)
    now = DateTime.utc_now()

    row = %__MODULE__{
      workspace_uri: ws,
      name: name,
      tag: tag,
      version_hash: version_hash,
      created_by: by,
      inserted_at: now,
      updated_at: now
    }

    # Upsert keyed by the UNIQUE (workspace_uri, name, tag) index. On
    # conflict we replace the hash + created_by + updated_at so a
    # re-`put` of an existing tag overwrites it.
    case Repo.insert(row,
           on_conflict: [set: [version_hash: version_hash, created_by: by, updated_at: now]],
           conflict_target: [:workspace_uri, :name, :tag]
         ) do
      {:ok, _} ->
        cache_put(ws, name, tag, version_hash)
        :ok

      {:error, _} = err ->
        err
    end
  end

  # --- resolve -----------------------------------------------------------

  @doc """
  Resolve a tag to its current version hash.

  Reads the ETS cache. Returns `{:ok, version_hash}` if the tag exists
  in the workspace, `:error` otherwise. A `stable` tag in another
  workspace never satisfies this lookup (the workspace is part of the
  key — SPEC §1.2 non-collision).
  """
  @spec resolve(URI.t() | String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | :error
  def resolve(workspace, name, tag) when is_binary(name) and is_binary(tag) do
    key = cache_key(uri_to_str(workspace), name, tag)

    case :ets.lookup(@table, key) do
      [{^key, hash}] -> {:ok, hash}
      [] -> :error
    end
  end

  # --- list --------------------------------------------------------------

  @doc """
  List every tag row in a workspace.

  Reads the Postgres table (the source of truth) — `list/1` is an admin /
  catalog read, not a hot path, and going to the DB keeps it correct
  under a test sandbox's per-test rollback. Returns `[t()]` ordered by
  `(name, tag)`.
  """
  @spec list(URI.t() | String.t()) :: [t()]
  def list(workspace) do
    ws = uri_to_str(workspace)

    from(r in __MODULE__,
      where: r.workspace_uri == ^ws,
      order_by: [asc: r.name, asc: r.tag]
    )
    |> Repo.all()
  end

  # --- move (CAS) --------------------------------------------------------

  @doc """
  Compare-and-swap a tag onto a new hash.

  Re-points `(workspace, name, tag)` onto `new_hash` **only if** the
  row currently points at `expected_hash`. Implemented as one atomic
  SQL `UPDATE ... WHERE version_hash = ?expected` — so when concurrent
  callers race to move the same tag, exactly one `UPDATE` matches and
  the rest match zero rows.

  Returns:
  - `:ok` — the CAS won; the tag now points at `new_hash`.
  - `{:error, :tag_moved}` — the row exists but no longer points at
    `expected_hash` (a concurrent move beat this caller, or the
    expected hash was simply wrong).
  - `{:error, :no_such_tag}` — there is no row for `(workspace, name,
    tag)` at all (use `put/5` to create it first).
  """
  @spec move(
          URI.t() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: :ok | {:error, :tag_moved} | {:error, :no_such_tag}
  def move(workspace, name, tag, expected_hash, new_hash)
      when is_binary(name) and is_binary(tag) and is_binary(expected_hash) and
             is_binary(new_hash) do
    ws = uri_to_str(workspace)
    now = DateTime.utc_now()

    # The atomic CAS: a single UPDATE whose WHERE clause pins the
    # expected prior hash. Postgres runs it as one atomic statement — the
    # affected row-count IS the compare-and-swap outcome.
    {updated, _} =
      from(r in __MODULE__,
        where:
          r.workspace_uri == ^ws and r.name == ^name and r.tag == ^tag and
            r.version_hash == ^expected_hash
      )
      |> Repo.update_all(set: [version_hash: new_hash, updated_at: now])

    case updated do
      1 ->
        cache_put(ws, name, tag, new_hash)
        :ok

      0 ->
        # Either the tag doesn't exist at all, or it exists but points
        # somewhere else. Distinguish so the caller gets a precise
        # error (`:no_such_tag` is fixable with `put/5`; `:tag_moved`
        # means re-read + retry).
        if tag_exists?(ws, name, tag) do
          {:error, :tag_moved}
        else
          {:error, :no_such_tag}
        end
    end
  end

  # --- boot hydration ----------------------------------------------------

  @doc """
  Hydrate the ETS read cache from the `template_tags` Postgres table.

  Called at boot (after `EzagentCore.Repo` is up) — the
  `Ezagent.Routing.RuleStore.load_into_registry/1` analogue. Clears the
  cache and re-populates it from every persisted row, so the cache
  reflects exactly what the DB holds.

  Returns `:ok`.
  """
  @spec load_into_registry() :: :ok
  def load_into_registry do
    rows = Repo.all(__MODULE__)

    :ets.delete_all_objects(@table)

    Enum.each(rows, fn r ->
      :ets.insert(@table, {cache_key(r.workspace_uri, r.name, r.tag), r.version_hash})
    end)

    :ok
  end

  # --- internals ---------------------------------------------------------

  defp tag_exists?(ws, name, tag) do
    from(r in __MODULE__,
      where: r.workspace_uri == ^ws and r.name == ^name and r.tag == ^tag,
      limit: 1
    )
    |> Repo.exists?()
  end

  defp cache_put(ws, name, tag, hash) do
    :ets.insert(@table, {cache_key(ws, name, tag), hash})
    :ok
  end

  # The ETS key bundles the full `(workspace, name, tag)` triple — the
  # workspace segment is what keeps workspace A's `stable` from
  # colliding with workspace B's `stable` (SPEC §1.2).
  defp cache_key(ws, name, tag), do: {ws, name, tag}

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s

  defp uri_to_str_or_nil(nil), do: nil
  defp uri_to_str_or_nil(u), do: uri_to_str(u)
end
