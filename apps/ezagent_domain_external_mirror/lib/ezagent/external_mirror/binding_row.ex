defmodule Ezagent.ExternalMirror.BindingRow do
  @moduledoc """
  Ecto schema for the `external_mirror_bindings` projection table
  (PR-EM-3 SPEC §7.1).

  **Pure data module.** The Session Kind's `:external_mirror` slice
  is the source of truth per P3; rows here are the durable projection
  written by `Ezagent.ActionSet.ExternalMirror.invoke(:bind, ...)` and
  deleted by `:unbind`. Read at boot by `init_slice/1` (Session-side
  rehydration) AND by `Ezagent.ExternalMirror.BootReconciler`
  (cross-session safety net).

  ## Natural key

  `(session_uri, adapter_id, target_id)` — the DB-side idempotency
  contract. Concurrent `:bind` for the same triple collides on the
  unique index; the action body treats the `Repo.insert/2` error as
  the "already bound" success path (mirroring the in-memory
  PerBindingSupervisor / WorkerRegistry idempotency from PR-EM-2).

  The `:id` field is a synthetic primary key (the
  `"<adapter_id>/<target_id>"` synthetic id from the slice) so
  `Repo.get/2` works without compound-key gymnastics; the natural-key
  uniqueness is enforced via `external_mirror_bindings_natural_key_index`.

  ## opts_json

  Caller-supplied binding-time metadata (adapter-specific). Stored
  JSON-encoded in a `:string` (text) field — the `:bind` / `:unbind`
  paths encode/decode via `Jason`. Empty default `"{}"`.
  """

  use Ecto.Schema

  import Ecto.Query

  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "external_mirror_bindings" do
    field(:session_uri, :string)
    field(:adapter_id, :string)
    field(:target_id, :string)
    field(:opts_json, :string, default: "{}")
    field(:bound_by, :string)
    field(:bound_at, :utc_datetime_usec)
    field(:workspace_uri, :string)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: String.t(),
          session_uri: String.t(),
          adapter_id: String.t(),
          target_id: String.t(),
          opts_json: String.t(),
          bound_by: String.t(),
          bound_at: DateTime.t(),
          workspace_uri: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Insert a binding row. Caller passes already-derived fields; this
  function does not re-derive workspace / IDs (the action body owns
  that — see `Ezagent.ActionSet.ExternalMirror.invoke(:bind, ...)`).

  Returns `{:ok, row}` on fresh insert, `{:error, changeset}` on
  natural-key collision (the action body MAPS that to `:ok` per the
  idempotency contract).

  ## codex r3 HIGH-3 fix (2026-05-25) — unique_constraint declared

  The changeset now declares `unique_constraint/3` against the
  migration's
  `external_mirror_bindings_natural_key_index` so that concurrent
  `:bind` for the same `(session_uri, adapter_id, target_id)` triple
  returns `{:error, %Changeset{}}` instead of raising
  `Ecto.ConstraintError` (which prior to this fix turned a routine
  idempotency case into a process crash). The Behavior's `:bind`
  action body already handles the changeset error as success.
  """
  @spec insert(map()) :: {:ok, t()} | {:error, term()}
  def insert(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, [
      :id,
      :session_uri,
      :adapter_id,
      :target_id,
      :opts_json,
      :bound_by,
      :bound_at,
      :workspace_uri
    ])
    |> Ecto.Changeset.validate_required([
      :id,
      :session_uri,
      :adapter_id,
      :target_id,
      :bound_by,
      :bound_at,
      :workspace_uri
    ])
    # Declare the natural-key unique_constraint. Without this, Ecto
    # raises Ecto.ConstraintError on collision (the underlying SQLite
    # constraint fires, but Ecto can't map it back to a changeset
    # error without a registered constraint declaration). With this,
    # concurrent :bind for the same triple gets back
    # {:error, %Changeset{}} — which the action body treats as the
    # idempotent "already exists" success path.
    #
    # ## Subtle: TWO constraint names for the same unique index
    #
    # The migration creates the index with a custom name
    # (`external_mirror_bindings_natural_key_index`). On Postgres,
    # `Repo.insert/2` would surface that exact name in the constraint
    # error. SQLite, however, doesn't expose the index name in its
    # error string; the Ecto SQLite adapter (`ecto_sqlite3`) reconstructs
    # a DEFAULT name from the column list:
    # `external_mirror_bindings_session_uri_adapter_id_target_id_index`.
    # We register BOTH so the changeset-error path works on either
    # adapter (V1 = SQLite; production paths may evolve to Postgres).
    #
    # The :id PK collision is similarly mapped — same triple → same
    # synthetic row_id (per row_id/3 hash) — so EITHER constraint
    # fires depending on race timing. Both produce the same shape of
    # changeset error for the caller.
    |> Ecto.Changeset.unique_constraint(:adapter_id,
      name: :external_mirror_bindings_natural_key_index,
      message: "binding already exists"
    )
    |> Ecto.Changeset.unique_constraint(:adapter_id,
      name: :external_mirror_bindings_session_uri_adapter_id_target_id_index,
      message: "binding already exists"
    )
    |> Ecto.Changeset.unique_constraint(:id,
      name: :external_mirror_bindings_pkey,
      message: "binding already exists"
    )
    |> Repo.insert()
  end

  @doc """
  Delete a binding row by its row id (the session-scoped SHA hash —
  see `row_id/3`). Returns a structured outcome so callers can
  distinguish a real deletion from a no-op:

  - `{:ok, :deleted}` — row existed and was deleted.
  - `{:ok, :not_found}` — no row matched `id` (row was already gone,
    or `id` doesn't correspond to any persisted binding).
  - `{:error, %Ecto.Changeset{}}` — `Repo.delete/1` failed
    (stale entry, FK violation, etc.).

  ## Task #53 (2026-05-27) — silent-success removal

  Pre-fix, this returned bare `:ok` for ALL three cases AND discarded
  the `Repo.delete/1` return value. That meant:

  - A row id that didn't match (e.g. session_uri normalization drift
    between bind and unbind, or another caller's racing delete)
    silently looked like a successful deletion. The slice claimed
    the binding was unbound (`unbound: true`) but the projection
    row stayed — next inbound dispatch found 2+ rows for the
    same chat_id and bounced with `:ambiguous_chat_binding`
    (Allen 2026-05-27 02:53 repro).
  - A real `Repo.delete` failure (stale entry, constraint violation,
    pool checkout error) was swallowed as success.

  The new contract surfaces both cases. Action bodies that expect
  the row to exist (because they just saw it in slice) MUST treat
  `{:ok, :not_found}` as a desync — see
  `Ezagent.ActionSet.ExternalMirror.do_unbind/4`.
  """
  @spec delete_by_id(String.t()) ::
          {:ok, :deleted | :not_found} | {:error, Ecto.Changeset.t()}
  def delete_by_id(id) when is_binary(id) do
    case Repo.get(__MODULE__, id) do
      nil ->
        {:ok, :not_found}

      %__MODULE__{} = row ->
        case Repo.delete(row) do
          {:ok, _row} -> {:ok, :deleted}
          {:error, %Ecto.Changeset{}} = err -> err
        end
    end
  end

  @doc """
  List every binding row for `session_uri`. Used by
  `Ezagent.ActionSet.ExternalMirror.init_slice/1` to rebuild the slice
  on Session Kind init.
  """
  @spec list_for_session(URI.t() | String.t()) :: [t()]
  def list_for_session(%URI{} = uri), do: list_for_session(URI.to_string(uri))

  def list_for_session(session_uri) when is_binary(session_uri) do
    Repo.all(
      from(r in __MODULE__,
        where: r.session_uri == ^session_uri,
        order_by: r.bound_at
      )
    )
  end

  @doc """
  List EVERY binding row across all sessions. Used by
  `Ezagent.ExternalMirror.BootReconciler` to walk the table at
  application boot (V1 single-node — multi-node sharding would
  filter by workspace_uri here).
  """
  @spec list_all() :: [t()]
  def list_all do
    Repo.all(from(r in __MODULE__, order_by: r.bound_at))
  end

  @doc """
  Reverse lookup: every session URI bound to `adapter_id`. Used by
  the `Ezagent.ExternalMirror.sessions_for_adapter/2` facade
  (replaces the PR-EM-1 stub).
  """
  @spec sessions_for_adapter(String.t()) :: [URI.t()]
  def sessions_for_adapter(adapter_id) when is_binary(adapter_id) do
    Repo.all(
      from(r in __MODULE__,
        where: r.adapter_id == ^adapter_id,
        select: r.session_uri,
        distinct: true
      )
    )
    |> Enum.map(&Ezagent.URI.new!/1)
  end

  @doc """
  List every binding row for `adapter_id` (full rows, not just session
  URIs). Used by `Ezagent.ExternalMirror.AdapterInstall.install/1`
  to reconcile persisted bindings the moment a plugin adapter
  registers — addressing codex r2 HIGH-1 (BootReconciler ran before
  adapter plugins booted).
  """
  @spec list_for_adapter(String.t()) :: [t()]
  def list_for_adapter(adapter_id) when is_binary(adapter_id) do
    Repo.all(
      from(r in __MODULE__,
        where: r.adapter_id == ^adapter_id,
        order_by: r.bound_at
      )
    )
  end

  @doc """
  Build the in-memory slice's `:binding_id` field from
  `(adapter_id, target_id)` — `"<adapter_id>/<target_id>"`. This is
  the slice-local key (one slice = one session, so the slice's bindings
  list is already session-scoped — `binding_id` doesn't need to carry
  the session URI).

  **DO NOT use this as the DB row `:id`.** The DB row primary key
  spans ALL sessions, so it MUST include the session URI to avoid
  cross-session collisions on common targets (e.g. two sessions both
  bound to Lark chat `oc_xxx` — see codex r1 CRIT 2026-05-25).

  For the DB row id, use `row_id/3` below.
  """
  @spec binding_id(String.t(), String.t() | term()) :: String.t()
  def binding_id(adapter_id, target_id) when is_binary(adapter_id) do
    "#{adapter_id}/#{stringify_target(target_id)}"
  end

  @doc """
  Build the canonical DB row `:id` for
  `(session_uri, adapter_id, target_id)` — a SHA256-derived 24-hex
  string that scopes across the WHOLE table.

  ## Why a hash, not a compound string

  - Stable: same triple → same id (so concurrent inserts collide
    on the primary key AND on the natural-key unique index).
  - Session-scoped: includes `session_uri` so two sessions binding
    the same adapter target produce DIFFERENT row ids (fixes codex
    r1 CRIT — pre-fix, the id was only `<adapter_id>/<target_id>`
    so two sessions binding the same Lark chat collided on the PK
    and an `:unbind` from one session would `Repo.get` the other's
    row).
  - Independent of the in-memory `binding_id`: the slice's
    `binding_id` stays human-readable `"<adapter>/<target>"`
    (it's slice-local — no cross-session collision risk because
    each Session Kind's slice is independently keyed).

  24 hex chars = 96 bits of entropy — collision-resistant for
  hundreds of millions of bindings; same SHA shape PR-EM-2's
  `WorkerSpawn.worker_uri_for/3` uses for Worker URI derivation,
  so the row id matches the worker URI hash component naturally
  (12 chars there for terse log URIs; 24 chars here for SQL PK
  safety).
  """
  @spec row_id(URI.t(), String.t(), term()) :: String.t()
  def row_id(%URI{} = session_uri, adapter_id, target_id) when is_binary(adapter_id) do
    :crypto.hash(
      :sha256,
      URI.to_string(session_uri) <> "/" <> adapter_id <> "/" <> stringify_target(target_id)
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end

  @doc """
  Delete a binding row by its full natural key
  `(session_uri, adapter_id, target_id)`. PR-EM-3 codex r1 CRIT fix
  (2026-05-25) — the prior `delete_by_id/1` keyed only by the
  slice's `binding_id` which is NOT session-scoped, so unbinding
  one session's binding could delete another session's row.

  Task #53 (2026-05-27) — returns a structured outcome instead of
  bare `:ok` (see `delete_by_id/1`). Action bodies that just saw
  the binding in slice should assert `{:ok, :deleted}` and treat
  `{:ok, :not_found}` as a desync (slice ≠ projection).

  ## codex PR #418 r1 HIGH (2026-05-27) — delete by natural-key columns

  Pre-fix, this delegated to `delete_by_id/1` after computing the
  CURRENT `row_id/3` hash. That fails for any row whose stored
  `:id` was derived from a DIFFERENT stringification of
  `session_uri` — and there is at least one such drift source in
  the codebase: the 2026-06-13 `data_migrate_default_to_system_uris`
  migration rewrites `external_mirror_bindings.session_uri` without
  recomputing `:id`. Pre-migration rows hashed against
  `session://default/...` end up with a `session_uri` column of
  `session://system/...` — `row_id` of the current URI looks up by
  a hash that does not match the stored row's `:id`, returns nil,
  and the unbind silently no-ops at the DB level.

  Post-fix: delete by `(session_uri, adapter_id, target_id)`
  matched against the actual COLUMNS. The natural-key unique
  index on these columns guarantees there is at most one row to
  delete; `delete_all` returns the affected-row count which we
  map to the `:deleted` / `:not_found` outcomes. Independent of
  the stored `:id` value, so it survives any row_id-derivation
  drift.
  """
  @spec delete_by_natural_key(URI.t(), String.t(), term()) ::
          {:ok, :deleted | :not_found} | {:error, term()}
  def delete_by_natural_key(%URI{} = session_uri, adapter_id, target_id)
      when is_binary(adapter_id) do
    session_uri_str = URI.to_string(session_uri)
    target_id_str = stringify_target(target_id)

    query =
      from(r in __MODULE__,
        where:
          r.session_uri == ^session_uri_str and
            r.adapter_id == ^adapter_id and
            r.target_id == ^target_id_str
      )

    case Repo.delete_all(query) do
      {0, _} -> {:ok, :not_found}
      {n, _} when n >= 1 -> {:ok, :deleted}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Canonical stringifier for an adapter target id (binary | atom |
  integer | other). Public so `Ezagent.ActionSet.ExternalMirror` reuses
  this one copy instead of carrying a byte-identical fork (#25 Phase-3
  FF-1 dedup, PR-3N).
  """
  @spec stringify_target(term()) :: String.t()
  def stringify_target(t) when is_binary(t), do: t
  def stringify_target(t) when is_atom(t), do: Atom.to_string(t)
  def stringify_target(t) when is_integer(t), do: Integer.to_string(t)
  def stringify_target(t), do: inspect(t)
end
