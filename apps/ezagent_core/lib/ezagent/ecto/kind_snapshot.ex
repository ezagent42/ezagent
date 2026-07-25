defmodule Ezagent.Ecto.KindSnapshot do
  @moduledoc """
  Ecto schema for `kind_snapshots` (Phase 4-completion Spec 04).

  Schema layout:
  - `uri` — primary key (one row per Kind instance)
  - `kind_type` — stable type atom per Decision #62
  - `state_binary` — `:erlang.term_to_binary/1` of the full slice map
    (lossless for MapSet / URI / DateTime / atoms)
  - `state` — legacy JSON column (Phase 1 / 5+ drop); kept for
    read-side fallback during the transition
  - `version` — schema version per Spec 04 §2.G
  - `inserted_at` / `updated_at`

  Writes go to `state_binary`; reads prefer `state_binary` then fall
  back to legacy `state` so the upgrade path is seamless.
  """

  use Ecto.Schema
  import Ecto.Query

  # C5 §3.4 repo injection — the Ecto Repo is a config injection (Oban-style),
  # never a literal spine reference, so the actor framework can run against an
  # isolated store. Wired at core boot (`Ezagent.Kind.Adapters.wire!/0`) to
  # `EzagentCore.Repo`.
  defp repo, do: Application.fetch_env!(:ezagent_actor, :repo)

  # C5 §3.4 PersistencePort — workspace derivation / query scoping / transient
  # retry go through the config-resolved port, never the literal
  # `Ezagent.Persistence` spine. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.PersistenceAdapter`.
  defp persistence, do: Application.fetch_env!(:ezagent_actor, :persistence)

  @primary_key {:uri, :string, autogenerate: false}
  schema "kind_snapshots" do
    field :kind_type, :string
    field :state_binary, :binary
    field :state, :map
    field :version, :integer, default: 0
    # Phase 9 PR-6 (SPEC v3 §7) — per-tenant data isolation. NOT NULL at
    # the DB layer; derived by `Ezagent.Kind.Snapshot.save_now/3` from
    # the snapshotted Kind URI via `Ezagent.Persistence.workspace_uri_for!/1`.
    # Stored as canonical `workspace://<name>` string.
    field :workspace_uri, :string
    # Lifecycle Phase A (SPEC 2026-05-29 §9 OQ-1) — the ever-created
    # marker. `false` until `Ezagent.Lifecycle.create/1` has run for
    # this URI; the boot path uses it to run `create` once vs `activate`
    # every start. Cleared (row deleted) by `destroy/2`.
    field :ever_created, :boolean, default: false
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc """
  Fetch a single snapshot row by URI. Returns the Ecto schema struct or nil.
  """
  @spec get(String.t()) :: %__MODULE__{} | nil
  def get(uri_str) when is_binary(uri_str), do: repo().get(__MODULE__, uri_str)

  @doc """
  Fetch snapshot rows for many URIs in ONE query (batch PK-in lookup).

  Returns the matched rows (a URI with no row is simply absent from the
  result) — the batch primitive behind `Ezagent.Kind.read_durable_many/3`, so
  rendering N durable rows costs one store query, never N per-URI reads.
  """
  @spec get_many([String.t()]) :: [%__MODULE__{}]
  def get_many(uri_strs) when is_list(uri_strs) do
    from(s in __MODULE__, where: s.uri in ^uri_strs) |> repo().all()
  end

  @doc """
  List all snapshot rows (for `/admin/snapshots` LV + `mix ezagent.snapshot.list`).
  Ordered by `updated_at` desc so most-recently-active Kinds appear first.

  **System-scope read** — boot-time `ReadyGate` replays EVERY snapshot
  via this listing so each Kind is hydrated regardless of workspace.
  Per SPEC v3 §7.2 documented exception: bypasses
  `scope_by_workspace/2` by design. Per-workspace listings should call
  `list_in_workspace/1`.
  """
  @spec list_all() :: [%__MODULE__{}]
  def list_all do
    from(s in __MODULE__, order_by: [desc: s.updated_at])
    |> repo().all()
  end

  @doc """
  List snapshot rows scoped to a single workspace. Per SPEC v3 §7.2 —
  the standard workspace-scoped read path. Use this for per-tenant
  admin UI (e.g. workspace dashboard showing only that tenant's
  Kinds), NOT `list_all/0`.
  """
  @spec list_in_workspace(URI.t() | String.t()) :: [%__MODULE__{}]
  def list_in_workspace(workspace_uri) do
    __MODULE__
    |> persistence().scope_by_workspace(workspace_uri)
    |> order_by([s], desc: s.updated_at)
    |> repo().all()
  end

  @doc """
  Upsert (insert or update) the snapshot for `uri_str`.

  Phase 9 PR-6 (SPEC v3 §7) — `workspace_uri_str` is the canonical
  `workspace://<name>` string the snapshot belongs to, derived by the
  caller from the Kind URI (entity URI carries it as path segment;
  session URI looked up via `WorkspaceRegistry`; workspace URI is
  itself). The column is NOT NULL — caller MUST supply.

  ## `opts[:mark_ever_created]` (Lifecycle Phase A — SPEC §9 OQ-1, F3)

  When `true`, the `ever_created` column is set to `true` in the SAME
  `INSERT`/`UPDATE` as the state binary — atomic with the initial Lifecycle
  snapshot persist. This closes the create-re-run window: there is no
  longer a separate fire-and-forget marker write that a crash could land
  AFTER the snapshot but BEFORE the marker. When the opt is absent /
  `false`, the column is left untouched (an UPDATE of an already-created
  row keeps its `true`; a fresh row defaults to `false`).
  """
  @spec upsert(String.t(), String.t(), binary(), non_neg_integer(), String.t(), keyword()) ::
          {:ok, %__MODULE__{}} | {:error, term()}
  def upsert(uri_str, kind_type_str, binary, version, workspace_uri_str, opts \\ [])
      when is_binary(uri_str) and is_binary(kind_type_str) and is_binary(binary) and
             is_integer(version) and is_binary(workspace_uri_str) and is_list(opts) do
    now = DateTime.utc_now()

    attrs = %{
      uri: uri_str,
      kind_type: kind_type_str,
      state_binary: binary,
      # Keep state as nil for new rows; legacy rows may have JSON
      version: version,
      workspace_uri: workspace_uri_str,
      updated_at: now
    }

    attrs =
      if Keyword.get(opts, :mark_ever_created, false) do
        Map.put(attrs, :ever_created, true)
      else
        attrs
      end

    do_upsert_with_retry(attrs, now, _attempt = 0)
  end

  defp do_upsert_with_retry(attrs, now, _attempt) do
    persistence().with_transient_retry(fn ->
      do_upsert_once(attrs, now)
    end)
  end

  defp do_upsert_once(attrs, now) do
    insert_attrs = Map.put(attrs, :inserted_at, now)

    conflict_set =
      attrs
      |> Map.drop([:uri])
      |> Map.to_list()

    %__MODULE__{}
    |> Ecto.Changeset.change(insert_attrs)
    |> repo().insert(on_conflict: [set: conflict_set], conflict_target: [:uri])
  end

  @doc "Delete the snapshot for `uri_str`. Returns `:ok` even if nothing existed."
  @spec delete(String.t()) :: :ok
  def delete(uri_str) when is_binary(uri_str) do
    from(s in __MODULE__, where: s.uri == ^uri_str) |> repo().delete_all()
    :ok
  end

  @doc """
  Clear snapshot state without dropping a Lifecycle principal's durable
  `ever_created` marker.

  Marker-bearing rows retain their metadata and replace state with an empty
  snapshot. On the next load Lifecycle therefore classifies the URI as
  `:existed` and skips `create/1`. Snapshot-only rows have no marker and retain
  the historical full-delete behavior.
  """
  @spec clear_state_preserving_marker(String.t()) :: :ok
  def clear_state_preserving_marker(uri_str) when is_binary(uri_str) do
    case repo().get(__MODULE__, uri_str) do
      %__MODULE__{ever_created: true} = row ->
        row
        |> Ecto.Changeset.change(state_binary: :erlang.term_to_binary(%{}), state: nil)
        |> repo().update!()

        :ok

      _row_or_nil ->
        delete(uri_str)
    end
  end

  @doc """
  Lifecycle Phase A (SPEC 2026-05-29 §9 OQ-1) — read the ever-created
  marker for `uri_str`.

  Returns `true` iff a snapshot row exists for the URI AND its
  `ever_created` column is `true`. A missing row means the URI was
  never created (or its `destroy/2` cleared it), so this returns
  `false` — the boot path must run `create/1`.

  This is the durable source of truth the Lifecycle boot path consults
  to decide `create` (once) vs `activate` (every start). It is robust
  to a legitimately-empty initial `state` (the column is independent of
  state content — that is exactly why OQ-1 chose a dedicated column over
  "snapshot-row-exists").
  """
  @spec ever_created?(String.t()) :: boolean()
  def ever_created?(uri_str) when is_binary(uri_str) do
    case repo().get(__MODULE__, uri_str) do
      %__MODULE__{ever_created: true} -> true
      _ -> false
    end
  end

  @doc """
  Lifecycle Phase A (SPEC 2026-05-29 §9 OQ-1) — flip the ever-created
  marker to `true` for an EXISTING snapshot row.

  Called by the Lifecycle boot path AFTER `create/1` has run and the
  initial `state` has been durably persisted (so the marker is never
  set ahead of the state it gates). A no-op `{:error, :no_row}` if the
  row does not exist yet (the caller persists state first via the
  normal `upsert/5` path, then marks).
  """
  @spec mark_ever_created(String.t()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def mark_ever_created(uri_str) when is_binary(uri_str) do
    case repo().get(__MODULE__, uri_str) do
      nil ->
        {:error, :no_row}

      row ->
        row
        |> Ecto.Changeset.change(%{ever_created: true, updated_at: DateTime.utc_now()})
        |> repo().update()
    end
  end

  @doc """
  Decode the snapshot's state map. Prefers `state_binary` (`term_to_binary`,
  lossless); falls back to legacy `state` (JSON). Returns `:error` if both
  are nil/empty.

  ## Why NOT `:safe` (Allen 2026-06-03 — cold-load rehydrate fix)

  `binary_to_term(bin, [:safe])` rejects any atom not ALREADY in the VM's
  atom table. The `:safe` flag exists to stop ATOM-TABLE INJECTION /
  exhaustion from UNTRUSTED input — it does not apply here: a snapshot is
  framework-authored TRUSTED data (our own `Ezagent.Kind.Snapshot.save_now`
  → `term_to_binary` of the Kind's state). User content in the state is
  strings/binaries (never atoms); every atom in a snapshot is a framework
  module name (`Ezagent.Message`, `Ezagent.Publisher.Event`, `DateTime`, …)
  or a struct/key atom.

  On a COLD restart, such a module atom may not be loaded at the moment the
  Kind decodes (BEAM loads modules lazily), so `:safe` raised → the caller
  saw `{:error, :unsafe_atom}` → the PR-4 fail-loud guard refused to wipe →
  the Kind could not rehydrate → inbound dispatch returned `:no_such_actor`
  (the live 传话游戏 relay session `s34full`). Injecting a malicious atom
  would require write access to the local `kind_snapshots` table, i.e. full
  host compromise — at which point `:safe` protects nothing. So we decode
  the trusted snapshot WITHOUT `:safe`.
  """
  @spec decode_state(%__MODULE__{}) :: {:ok, map()} | {:error, term()}
  def decode_state(%__MODULE__{state_binary: bin}) when is_binary(bin) and byte_size(bin) > 0 do
    try do
      term = :erlang.binary_to_term(bin)

      if is_map(term) do
        {:ok, term}
      else
        {:error, {:not_a_map, term}}
      end
    rescue
      e -> {:error, {:decode_failed, e}}
    end
  end

  def decode_state(%__MODULE__{state: state}) when is_map(state), do: {:ok, state}
  def decode_state(%__MODULE__{}), do: :error
end
