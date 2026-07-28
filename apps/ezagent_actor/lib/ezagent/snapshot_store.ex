defmodule Ezagent.SnapshotStore do
  @moduledoc """
  Framework-internal store for per-Kind state snapshots.

  Phase 1 primitive (SPEC `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
  §5.2). Wraps the existing `kind_snapshots` table (schema:
  `Ezagent.Ecto.KindSnapshot`) behind a small, plugin-invisible API the
  framework's StateRebuilder + Kind.Host can call.

  ## Snapshot policy is framework-decided

  Per SPEC r2 codex closure (HIGH-3) — snapshot policy is NOT
  per-Behavior. Plugin authors CANNOT tune this. The policy is a
  single decision tree that lives in this module:

  - **Snapshot every N events** (default `100`, configurable via app
    env `:ezagent_core, :snapshot_every_n_events`) — the framework's
    EventLog increments an event counter per aggregate URI; when the
    counter hits N, the framework calls `write/3` with the current
    Kind state.
  - **Snapshot on graceful terminate** — the framework's `Kind.Host`
    `terminate/2` (or the per-Kind shutdown hook) calls `write/3`
    one final time before the process exits.

  No `:on_change` / `:on_terminate` / per-pattern enum. To revisit
  policy in future, edit this module — never expose it as Kind /
  Behavior tunable. (Codex r2 closure: "framework decides policy,
  plugin authors pick the pattern.")

  ## API surface (framework-internal)

  | Function       | Caller                                       |
  |----------------|----------------------------------------------|
  | `latest/1`     | `Ezagent.Kind.StateRebuilder.rebuild/1`      |
  | `write/3`      | `Ezagent.EventLog` (every-N) + Kind.Host terminate |
  | `delete/1`     | Saga compensation + `Behavior` destroy effect |
  | `count/0`      | Ops dashboards / `mix ezagent.snapshots.*`   |

  Plugin code MUST NOT import this module — SPEC §11 enforces via grep gate.

  ## Phase 1 coexistence with legacy adapter

  This module DOES NOT replace `Ezagent.Kind.Snapshot` in Phase 1. The
  legacy module (which carries the per-Kind `persistence/0` enum
  dispatch) continues to be the production write path until Phase 2
  migrations cut Kinds over to Behavior-emitted effects. This module
  is the seam Phase 2+ writes through — its existence in Phase 1 is
  purely the API stake-in-the-ground that StateRebuilder + EventLog
  can rely on.

  Both modules read/write the SAME `kind_snapshots` table. They are
  not in contention: legacy writers write per Kind's declared
  `persistence/0`; this module's writers (Phase 2+) write per the
  framework-decided every-N + on-terminate policy. A Kind migrated
  to Phase 2 stops declaring `persistence/0` — only one writer
  touches each row.

  ## Errors

  - `latest/1` returns `{:error, :not_found}` when no row exists.
  - `write/3` returns `{:error, :missing_kind_type}` when caller omits
    `:kind_type` opt (it's required — without it, restore can't
    version-check).
  - `write/3` returns `{:error, reason}` for changeset / DB errors —
    raise-on-infrastructure follows the existing `KindSnapshot.upsert`
    contract.
  - `delete/1` is idempotent — returns `:ok` whether or not a row
    existed.

  ## Version auto-increment

  When caller omits `:version`, this module reads the current row's
  version (or 0 if no row) and increments by 1 before writing.
  Callers that own the version (e.g. compaction tools, replay
  utilities) supply `:version` explicitly.

  ## Workspace derivation

  Per SPEC v3 §7 the `workspace_uri` column is NOT NULL. The store
  derives it from the Kind URI via the same chokepoint
  `Ezagent.Kind.Snapshot.save_now/3` already uses (`Ezagent.Persistence.workspace_uri_for/1`
  + inlined `"workspace://system"` literal for `system://` schemes).
  Callers MAY pass `:workspace_uri` explicitly to override (e.g. when
  the URI scheme is workspace-bound but the snapshot belongs to a
  cross-cutting context).
  """

  require Logger

  alias Ezagent.Ecto.KindSnapshot

  @default_snapshot_every_n_events 100

  @typedoc """
  Latest-snapshot read shape. `:updated_at` is the row's
  `updated_at` column (UTC microsecond resolution).
  """
  @type latest_result :: %{
          state: map(),
          version: non_neg_integer(),
          updated_at: DateTime.t()
        }

  @typedoc """
  `write/3` opts.

  - `:kind_type` (REQUIRED) — atom or string identifying the Kind type
    (e.g. `:user`, `"session"`). Persisted so a future read can refuse
    snapshots written by a different Kind module.
  - `:workspace_uri` (optional) — canonical `workspace://<name>` string.
    Defaults to structural derivation from `uri` via
    `Ezagent.Persistence.workspace_uri_for/1`, with `system://` URIs
    landing in `workspace://system` (SPEC #324 rev 3).
  - `:version` (optional) — explicit version integer. Defaults to
    `current_row.version + 1` (or 1 if no row exists).
  """
  @type write_opts :: [
          kind_type: atom() | String.t(),
          workspace_uri: String.t(),
          version: non_neg_integer()
        ]

  @doc """
  Framework-configured snapshot cadence. Reads
  `:ezagent_core, :snapshot_every_n_events` from app env; falls back
  to the compile-time default (`#{@default_snapshot_every_n_events}`).

  This is the ONLY tunable — and it's an ops/config knob, not a
  plugin-author API.
  """
  @spec snapshot_every_n_events() :: pos_integer()
  def snapshot_every_n_events do
    Application.get_env(
      :ezagent_core,
      :snapshot_every_n_events,
      @default_snapshot_every_n_events
    )
  end

  @doc """
  Fetch the latest snapshot for `uri`.

  Returns `{:ok, %{state: state, version: v, updated_at: dt}}` on hit,
  `{:error, :not_found}` on miss.

  Decoding follows `Ezagent.Ecto.KindSnapshot.decode_state/1` — prefers
  `state_binary` (lossless `term_to_binary`), falls back to legacy
  JSON `state`. `:safe` flag on `binary_to_term` rejects unknown
  atoms.
  """
  @spec latest(URI.t() | String.t()) ::
          {:ok, latest_result()} | {:error, :not_found | term()}
  def latest(uri) do
    uri_str = uri_to_str(uri)

    case KindSnapshot.get(uri_str) do
      nil ->
        {:error, :not_found}

      row ->
        case KindSnapshot.decode_state(row) do
          {:ok, state} ->
            {:ok,
             %{
               state: state,
               version: row.version || 0,
               updated_at: row.updated_at
             }}

          :error ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Write (upsert) `state` for `uri`.

  Required opts: `:kind_type`.

  Optional opts: `:workspace_uri` (derived from `uri` if omitted),
  `:version` (auto-increment from current row if omitted).

  Returns `{:ok, %{version: v}}` on success — the version actually
  persisted (useful when caller relies on auto-increment).

  ## Failure modes

  - `{:error, :missing_kind_type}` — caller forgot the required opt.
  - `{:error, reason}` — changeset / DB error from
    `KindSnapshot.upsert/5`.
  - Raises `ArgumentError` if the URI's workspace cannot be derived
    and no `:workspace_uri` is given (mirrors
    `Ezagent.Kind.Snapshot.derive_workspace_uri/1` strict contract;
    SPEC #324 rev 3 forbids silent fallback).
  """
  @spec write(URI.t() | String.t(), map(), write_opts()) ::
          {:ok, %{version: non_neg_integer()}} | {:error, term()}
  def write(uri, state, opts \\ []) when is_map(state) do
    case Keyword.fetch(opts, :kind_type) do
      :error ->
        {:error, :missing_kind_type}

      {:ok, kind_type} ->
        do_write(uri, state, kind_type, opts)
    end
  end

  defp do_write(uri, state, kind_type, opts) do
    uri_str = uri_to_str(uri)
    kind_type_str = stringify_kind_type(kind_type)
    workspace_uri_str = derive_workspace(uri, opts)
    # Lifecycle Phase A (SPEC 2026-05-29 §0.1 + §10-R2, codex r2 F1) —
    # strip every Lifecycle slice's `:transients` sub-key BEFORE
    # serialization, mirroring `Ezagent.Kind.Snapshot.save_now/3`. This is
    # the Phase 2+ durable-write seam (this module's moduledoc points
    # future writers here), so it MUST enforce the same transient-leak
    # invariant as every other durable-write path (`save_now/3`, the
    # `:on_change` dirty-check in `Kind.Runtime`, the Publisher ring): a
    # transient (PID / ref / ETS handle / port / monitor ref) has no
    # serialization path by construction and is rebuilt by `activate/2` on
    # the next start. Legacy (non-Lifecycle) flat slices carry no
    # `:transients` sub-key, so the strip is a structural no-op and the
    # serialized bytes are identical. `strip_transients/1` is a plain
    # runtime function in `Ezagent.Kind.Snapshot` — calling it here
    # introduces NO module cycle (Kind.Snapshot does not reference
    # SnapshotStore; both live in :ezagent_core), so no helper relocation
    # was needed.
    binary = :erlang.term_to_binary(Ezagent.Kind.Snapshot.strip_transients(state))

    version =
      case Keyword.fetch(opts, :version) do
        {:ok, v} when is_integer(v) and v >= 0 -> v
        :error -> next_version(uri_str)
      end

    case KindSnapshot.upsert(uri_str, kind_type_str, binary, version, workspace_uri_str) do
      {:ok, _row} ->
        :telemetry.execute(
          [:ezagent, :snapshot_store, :written],
          %{bytes: byte_size(binary)},
          %{uri: uri_str, kind_type: kind_type_str, version: version}
        )

        maybe_dual_write_identity_caps(uri_str, state)

        {:ok, %{version: version}}

      {:error, reason} ->
        Logger.warning("Ezagent.SnapshotStore: write failed for #{uri_str}: #{inspect(reason)}")

        :telemetry.execute(
          [:ezagent, :snapshot_store, :failed],
          %{},
          %{uri: uri_str, kind_type: kind_type_str, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Delete the snapshot row for `uri`. Idempotent — returns `:ok`
  whether or not a row existed.
  """
  @spec delete(URI.t() | String.t()) :: :ok
  def delete(uri) do
    result =
      uri
      |> uri_to_str()
      |> KindSnapshot.clear_state_preserving_marker()

    maybe_clear_identity_caps_store(uri)

    result
  end

  # #189 PR-1 dual-write (identity-plane cutover step 1, ADDITIVE): direct
  # snapshot writes/deletes mirror their `:identity` slice into the unified
  # identity-caps store (config-injected via `:ezagent_actor,
  # :identity_caps_store` — no compile-time reference from the actor layer
  # to the domain store), keeping the store an exact mirror of the durable
  # snapshot plane even for writers that bypass `Kind.Server` commits. The
  # domain store module never raises and decides what to skip (user URIs
  # mirror via `users.caps_json`; slices without a caps set are ignored).
  defp maybe_dual_write_identity_caps(uri_str, state) do
    with %{identity: identity_slice} <- state,
         store when not is_nil(store) <-
           Application.get_env(:ezagent_actor, :identity_caps_store),
         true <- Code.ensure_loaded?(store) do
      store.sync_committed_identity(uri_str, nil, identity_slice)
    else
      _ -> :ok
    end
  end

  defp maybe_clear_identity_caps_store(uri) do
    case Application.get_env(:ezagent_actor, :identity_caps_store) do
      nil ->
        :ok

      store ->
        if Code.ensure_loaded?(store) do
          store.identity_snapshot_cleared(uri)
        else
          :ok
        end
    end
  end

  @doc """
  Total snapshot row count. Used by ops dashboards + replay tooling.
  """
  @spec count() :: non_neg_integer()
  def count do
    repo().aggregate(KindSnapshot, :count, :uri)
  end

  # C5 §3.4 repo injection — the Ecto Repo is a config injection (Oban-style),
  # never a literal spine reference. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to `EzagentCore.Repo`.
  defp repo, do: Application.fetch_env!(:ezagent_actor, :repo)

  # C5 §3.4 PersistencePort — workspace derivation goes through the
  # config-resolved port, never the literal `Ezagent.Persistence` spine.
  # Wired at core boot (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.PersistenceAdapter`.
  defp persistence, do: Application.fetch_env!(:ezagent_actor, :persistence)

  # ---------------------------------------------------------------------
  # Internals

  defp next_version(uri_str) do
    case KindSnapshot.get(uri_str) do
      nil -> 1
      row -> (row.version || 0) + 1
    end
  end

  defp stringify_kind_type(kt) when is_atom(kt), do: Atom.to_string(kt)
  defp stringify_kind_type(kt) when is_binary(kt), do: kt

  # Mirrors `Ezagent.Kind.Snapshot.derive_workspace_uri/1` (SPEC #324 rev 3):
  # caller may pass `:workspace_uri` explicitly; otherwise we derive from
  # the URI via the canonical chokepoint, with `system://` URIs landing
  # in `workspace://system` (the documented cross-cutting sink). Every
  # other un-derivable scheme RAISES so the caller can't silently land
  # in admin.
  defp derive_workspace(uri, opts) do
    case Keyword.fetch(opts, :workspace_uri) do
      {:ok, ws} when is_binary(ws) ->
        ws

      :error ->
        parsed =
          case uri do
            %URI{} = u -> u
            s when is_binary(s) -> Ezagent.URI.new!(s)
          end

        case persistence().workspace_uri_for(parsed) do
          {:ok, ws} ->
            ws

          {:error, :no_workspace} ->
            case parsed do
              %URI{scheme: "system"} ->
                # System-tier snapshot — admin's workspace is the
                # structural sink (SPEC v3 §13.1).
                Ezagent.URI.workspace(:system) |> URI.to_string()

              other ->
                raise ArgumentError,
                      "Ezagent.SnapshotStore.write/3: cannot derive workspace for " <>
                        "URI=#{inspect(other)}. Per SPEC #324 rev 3, only the 4 " <>
                        "per-tenant schemes (entity/workspace/session derive " <>
                        "structurally) and system scope (lands in the system workspace) " <>
                        "are accepted. Pass :workspace_uri explicitly if this Kind " <>
                        "lives outside the standard derivation."
            end
        end
    end
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end
