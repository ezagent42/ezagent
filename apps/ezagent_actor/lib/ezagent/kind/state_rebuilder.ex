defmodule Ezagent.Kind.StateRebuilder do
  @moduledoc """
  Framework-internal: rebuild a Kind's in-memory state from its
  persisted snapshot (Phase 1) and, in Phase 2+, fold subsequent
  events on top.

  Phase 1 primitive (SPEC `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
  §5.3). Generalises the per-domain `BootReconciler` pattern (today
  only `Ezagent.ExternalMirror.BootReconciler` exists — it stays
  as-is for Phase 1 per the SPEC §6 phasing; Phase 2+ refactors it
  to delegate here).

  ## Behaviour contract

  A Kind module that wants custom rebuild semantics implements this
  behaviour:

  - `rebuild_from_snapshot/1` (REQUIRED) — accepts the
    `Ezagent.SnapshotStore.latest/1` read shape (`%{state, version}`)
    and returns `{:ok, kind_state}` or `{:error, reason}`.

  Most Kinds don't need a custom implementation — the default
  `rebuild/1` path uses the snapshot's state map directly and
  doesn't require the Kind to implement this behaviour at all.

  ## Lazy-on-first-load (NOT eager boot rebuild)

  Per SPEC §5.3 + OQ-8: rebuild happens when the Router dispatches
  to an entity URI that isn't yet in the registry. The Router calls
  `rebuild/1` as part of the lazy-spawn path, NOT at application
  boot. Concretely:

  1. Router receives `dispatch(uri, ...)`.
  2. Looks up `uri` in `Ezagent.KindRegistry`.
  3. Miss → spawns the Kind via `Kind.spawn/2`; `Kind.Host.init/1`
     calls `StateRebuilder.rebuild(uri)` to seed the GenServer
     state.

  Phase 1 ships the API. Wiring into the lazy-spawn path lives in
  the Router (subagent A's branch) or in `Ezagent.Kind.Server.init/1`'s
  existing snapshot-load step (`Ezagent.Kind.Snapshot.load_or_init/3`).
  Phase 2+ rewires those callers to call `StateRebuilder.rebuild/1`
  instead.

  ## `rebuild_all/1` is a tooling helper

  `rebuild_all/1` walks every snapshot row (optionally scoped to a
  workspace) and tries to rebuild each. Returns a summary map.
  Used by:

  - `mix ezagent.snapshots.replay` (planned — SPEC §5.2 references
    a one-shot tool for forced rebuild post-Phase-3).
  - Operator UIs that surface "snapshots written N events ago that
    have never been replayed."

  NOT called automatically at boot (per OQ-8). Lazy rebuild is the
  hot path; this is for explicit bulk operations only.

  ## Failure modes

  - `rebuild/1` returns `{:error, :not_found}` if no snapshot row
    exists AND the Kind module doesn't supply a fresh-init fallback
    (this is the "first dispatch ever" case — caller is expected to
    treat it as "spawn fresh" not "fail dispatch").
  - `rebuild/1` returns `{:error, reason}` if snapshot decode fails
    (bad term_to_binary blob, version mismatch, etc.).
  - `rebuild_all/1` never raises — it accumulates failures into the
    summary's `:failed` list and continues.

  ## Plugin authors NEVER call this

  This module is framework-internal. The boundary is enforced by
  SPEC §11's grep gate: no `apps/ezagent_domain_*` file may import
  `Ezagent.Kind.StateRebuilder`.
  """

  require Logger

  alias Ezagent.SnapshotStore

  @typedoc """
  Snapshot read shape passed to `rebuild_from_snapshot/1` — the same
  shape `SnapshotStore.latest/1` returns.
  """
  @type snapshot :: %{
          state: map(),
          version: non_neg_integer(),
          updated_at: DateTime.t()
        }

  @typedoc """
  Return shape of `rebuild/1` — the state plus a tag identifying how
  it was built.

  - `:snapshot` — restored from a `kind_snapshots` row.
  - `:events` — rebuilt by folding events (Phase 2+).
  - `:none` — no snapshot, no events — caller should treat as
    fresh-init.
  """
  @type rebuild_source :: :snapshot | :events | :none

  @typedoc """
  `rebuild_all/1` summary. `:rebuilt` is the count of successful
  rebuilds; `:failed` is `[{uri, reason}]`; `:skipped` is
  `[{uri, reason}]` (e.g. row exists but no Kind module is
  registered for the URI scheme — the row is orphaned).
  """
  @type rebuild_all_result :: %{
          rebuilt: non_neg_integer(),
          failed: [{String.t(), term()}],
          skipped: [{String.t(), term()}]
        }

  @callback rebuild_from_snapshot(snapshot :: snapshot()) ::
              {:ok, kind_state :: map()} | {:error, term()}

  @doc """
  Rebuild a Kind's in-memory state for `uri`.

  1. `SnapshotStore.latest(uri)` → if hit, return the snapshot's
     state with `{:from, :snapshot}`.
  2. If miss, return `{:error, :not_found}` — caller decides
     whether to fresh-init (the standard case) or treat as
     dispatch failure.

  ## Return

  - `{:ok, state, %{from: :snapshot}}` — snapshot hit.
  - `{:error, :not_found}` — no snapshot — caller fresh-inits.
  - `{:error, reason}` — decode / version failure.
  """
  @spec rebuild(URI.t() | String.t()) ::
          {:ok, map(), %{from: rebuild_source()}} | {:error, term()}
  def rebuild(uri) do
    case SnapshotStore.latest(uri) do
      {:ok, snapshot} ->
        {:ok, snapshot.state, %{from: :snapshot}}

      {:error, :not_found} ->
        # No snapshot row. Return :not_found so the caller can decide
        # between fresh-init (the normal case) vs. dispatch-time error
        # (an unbound URI that has no fresh constructor — rare).
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning(
          "Ezagent.Kind.StateRebuilder: rebuild failed for #{inspect(uri)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Cheap existence check — does `uri` have a `kind_snapshots` row?

  Used by `Ezagent.Invocation.dispatch/1`'s cold-spawn-from-snapshot
  path (codex E2E fix v2 Bug B, 2026-05-29). The dispatch chokepoint
  must decide quickly whether a `:unknown`-status URI is genuinely
  "never existed" (legacy `:no_such_actor` return) or "snapshot
  exists, just not in-memory" (lazy-spawn via `SpawnRegistry.spawn/1`).

  `SnapshotStore.latest/1` already does a single PK lookup on
  `kind_snapshots` (no decode pre-load), but this thin wrapper drops
  the decoded `:state` map so the caller doesn't pay the
  `binary_to_term/:safe` allocation just to discover existence.

  Returns `true` iff a row exists. Decoding errors (corrupt blob,
  unknown atoms) ALSO return `true` — the row IS there; the dispatch
  path will then either spawn (and the `Kind.Server.init/1` `load_or_init`
  will hit the same decode error + use fresh init per its
  `{:error, _} -> fresh` fallback) or the spawn fn itself will fail
  cleanly. Treating a decode error as "not found" here would silently
  hide a real corruption from the dispatch caller.

  Failure modes:
  - DB unreachable / Repo not started — returns `false` (degraded:
    we cannot prove existence, so don't claim it; the dispatch falls
    back to `:no_such_actor`).
  """
  @spec snapshot_exists?(URI.t() | String.t()) :: boolean()
  def snapshot_exists?(uri) do
    case SnapshotStore.latest(uri) do
      {:ok, _snapshot} -> true
      # A `{:error, :not_found}` from `KindSnapshot.decode_state/1` is
      # actually "row exists but no decodable state field." Treat as
      # not-existing for the dispatch path's purposes — a row with no
      # decodable state can't be brought up.
      {:error, :not_found} -> false
      # Other decode errors (corrupt term_to_binary blob, version
      # mismatch) → return `true` so the dispatch path attempts spawn,
      # which surfaces the underlying error rather than silently
      # masking corruption as `:no_such_actor`.
      {:error, _reason} -> true
    end
  rescue
    e ->
      Logger.warning(
        "Ezagent.Kind.StateRebuilder.snapshot_exists?: snapshot lookup raised for " <>
          "#{inspect(uri)}: #{inspect(e)} — treating as not-existing"
      )

      false
  catch
    :exit, reason ->
      Logger.warning(
        "Ezagent.Kind.StateRebuilder.snapshot_exists?: snapshot lookup exited for " <>
          "#{inspect(uri)}: #{inspect(reason)} — treating as not-existing"
      )

      false
  end

  @doc """
  Rebuild a Kind's state using a Kind-module callback rather than
  returning the raw snapshot state.

  Equivalent to `rebuild/1` but routes a snapshot hit through
  `kind_module.rebuild_from_snapshot/1` first — gives the Kind a
  chance to apply pre-fold transformations (e.g. URI canonicalization,
  slice pruning) without baking that logic into this module.

  Callers that don't need a custom transform should prefer `rebuild/1`.
  """
  @spec rebuild(URI.t() | String.t(), module()) ::
          {:ok, map(), %{from: rebuild_source()}} | {:error, term()}
  def rebuild(uri, kind_module) when is_atom(kind_module) do
    with {:ok, snapshot} <- SnapshotStore.latest(uri),
         {:ok, rebuilt_state} <- apply_snapshot_callback(kind_module, snapshot) do
      {:ok, rebuilt_state, %{from: :snapshot}}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Bulk-rebuild every snapshot row.

  Walks `Ezagent.Ecto.KindSnapshot.list_all/0` (system-scope) or
  `list_in_workspace/1` and tries `rebuild/1` for each URI.

  Returns a summary `%{rebuilt: n, failed: [...], skipped: [...]}`.
  Does NOT raise — every per-URI failure is captured. Used by
  `mix ezagent.snapshots.replay` and admin tooling.

  ## Phase 1 scope

  This function does NOT spawn Kind processes — it only rebuilds
  state via `rebuild/1` and counts the result. Wiring into spawn
  lives in the Router. A successful entry in `:rebuilt` means "the
  state could be decoded + (if Phase 2+) folded"; it does NOT mean
  "a Kind process is running."

  ## Workspace filter

  Pass `:all` (default) to walk every workspace, or a workspace URI
  to scope to one tenant. `:all` is the operator-tier mass-replay
  case; per-workspace is the per-tenant remediation case.
  """
  @spec rebuild_all(:all | URI.t() | String.t()) :: rebuild_all_result()
  def rebuild_all(workspace \\ :all)

  def rebuild_all(:all) do
    Ezagent.Ecto.KindSnapshot.list_all()
    |> do_rebuild_all()
  end

  def rebuild_all(workspace) do
    Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace)
    |> do_rebuild_all()
  end

  defp do_rebuild_all(rows) do
    Enum.reduce(rows, %{rebuilt: 0, failed: [], skipped: []}, fn row, acc ->
      case safe_rebuild(row.uri) do
        {:ok, _state, _meta} ->
          %{acc | rebuilt: acc.rebuilt + 1}

        {:error, :not_found} ->
          # Listed by KindSnapshot.list_all → not_found means the row
          # was deleted between list + rebuild (race) OR the decode
          # path returned `:error` because both state_binary and state
          # are nil/empty. Either way, skip — not a failure.
          %{acc | skipped: [{row.uri, :not_found} | acc.skipped]}

        {:error, reason} ->
          %{acc | failed: [{row.uri, reason} | acc.failed]}
      end
    end)
  end

  # Each per-URI rebuild is wrapped — a single malformed row should
  # not crash the whole replay. Mirrors `Snapshot.Writer.flush_now/1`
  # rescue pattern. Bulk operators see the failure in the summary.
  defp safe_rebuild(uri) do
    rebuild(uri)
  rescue
    e ->
      Logger.warning(
        "Ezagent.Kind.StateRebuilder.rebuild_all: rebuild raised for #{uri}: #{inspect(e)} — skipping"
      )

      {:error, {:raised, e}}
  catch
    :exit, reason ->
      Logger.warning(
        "Ezagent.Kind.StateRebuilder.rebuild_all: rebuild exited for #{uri}: #{inspect(reason)} — skipping"
      )

      {:error, {:exited, reason}}
  end

  defp apply_snapshot_callback(kind_module, snapshot) do
    if function_exported?(kind_module, :rebuild_from_snapshot, 1) do
      kind_module.rebuild_from_snapshot(snapshot)
    else
      # No custom rebuild — return the snapshot state directly.
      {:ok, snapshot.state}
    end
  end
end
