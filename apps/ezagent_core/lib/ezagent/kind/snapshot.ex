defmodule Ezagent.Kind.Snapshot do
  @moduledoc """
  Per-Kind state persistence (Phase 4-completion Spec 04).

  Each Kind declares `persistence/0` from one of:
  - `:ephemeral` — no persistence (default for most Kinds)
  - `{:snapshot, :on_change}` — sync write after every dispatch where
    `new_slice != old_slice` (Decision #59); restore on boot
  - `{:snapshot, :periodic, ms}` — async write every `ms` via
    `Ezagent.Snapshot.Writer`; restore on boot
  - `:on_terminate` — write on `GenServer.terminate/2`; restore on boot
  - `:external` — slice state lives in a foreign system; this module
    does NOT touch the DB; plugin author's `init_slice/1` reads from
    the foreign system

  Per Decision #62: snapshots key by `kind_type` (stable atom) — module
  rename doesn't orphan rows. Per Decision #59: `:on_change` writes
  only when the slice content actually differs (BEAM value equality).

  ## Sync vs async (Q2)

  Per Spec 04 Q2 default: `:on_change` is **sync** (~1ms SQLite local;
  zero loss within process lifetime); `:periodic` is **async** via
  `Ezagent.Snapshot.Writer` (mirrors `Ezagent.Audit.Writer` pattern from
  Decision #60).

  ## Failure mode (Q3)

  Write failure does NOT crash the Kind. Log + `[:ezagent, :persistence,
  :failed]` telemetry; the in-memory slice is the truth until next
  write succeeds. `feedback_let_it_crash_no_workarounds` applies to
  invariant violations, not external resource exhaustion (disk full).

  ## Restore safety

  `:erlang.binary_to_term/2` is called with `[:safe]` flag — rejects
  atoms not already loaded in the runtime (security against
  snapshot-table-write-then-bootstrap-arbitrary-atom attacks).
  """

  require Logger
  alias Ezagent.Ecto.KindSnapshot

  @doc """
  Load a snapshot for `uri` or return an initial state. Persistence
  policy determines whether DB is touched.

  Returns a state map keyed by `behavior.state_slice()`.
  """
  @spec load_or_init(URI.t() | String.t(), module(), map()) :: %{atom() => map()}
  def load_or_init(uri, kind_module, args) do
    case Ezagent.Kind.persistence_of(kind_module) do
      :ephemeral ->
        init_fresh(kind_module, args)

      :external ->
        # Plugin author's init_slice/1 reads from foreign system; don't touch DB.
        init_fresh(kind_module, args)

      :on_terminate ->
        load_with_fallback(uri, kind_module, args)

      {:snapshot, _strategy} ->
        load_with_fallback(uri, kind_module, args)
    end
  end

  defp load_with_fallback(uri, kind_module, args) do
    uri_str = uri_to_str(uri)
    fresh = init_fresh(kind_module, args)

    case fetch_snapshot(uri_str, kind_module) do
      {:ok, loaded_state} ->
        emit_restored(uri_str, loaded_state)
        # SPEC 2026-05-27-uri-canonicalization §9.2.1 (OQ-4 option b)
        # — canonicalize every `%URI{}` embedded in the decoded state
        # BEFORE the merge. Pre-migration snapshots may contain
        # `URI.parse`-built structs (authority:"user") that would
        # silently fail struct-equality comparisons against canonical
        # peers. The walker rewrites them in-place via the canonical
        # chokepoint.
        #
        # Merge so newly-added Behaviors get fresh init values (Q5).
        # Allen 2026-05-26 (codex HIGH-2 closure) — also PRUNE slice
        # keys for Behaviors the Kind no longer declares. A Behavior
        # that USED to live on this Kind (e.g. `Behavior.ApiKeys` on
        # `User` pre 2026-05-26 flip) leaves orphan slice content in
        # `state_binary` that no Behavior reads anymore. Without
        # pruning, AutoDerive LV would render that data (e.g.
        # plaintext API keys) verbatim because it walks the raw
        # slice map. Pruning at load drops the orphan from the live
        # state immediately; the next `:on_change` persistence then
        # writes the pruned shape back to disk, so the orphan is
        # also evicted from the DB on first mutation post-flip.
        #
        # Allen 2026-05-26 task #34 — also RECONCILE each Behavior
        # with its DB projection (if it declares
        # `reconcile_after_load/2`). This catches DB rows inserted
        # AFTER the last snapshot but BEFORE the next Kind restart
        # — e.g. ExternalMirror bindings written outside dispatch
        # OR a snapshot/DB write race. Idempotent for normal-path
        # callers.
        canonicalized = canonicalize_uris(loaded_state)

        fresh
        |> Map.merge(canonicalized)
        |> prune_orphan_slices(kind_module)
        |> reconcile_after_load_behaviors(uri, kind_module)

      :error ->
        fresh

      {:error, reason} ->
        Logger.warning(
          "Ezagent.Kind.Snapshot: load failed for #{uri_str}: #{inspect(reason)}; using fresh init"
        )

        fresh
    end
  end

  # Allen 2026-05-26 (codex HIGH-2) — drop any slice keys not declared
  # by the Kind's current `behaviors/0`. Keys to drop come from snapshot
  # state that survived a Behavior removal (e.g. ApiKeys-to-Agent flip
  # left `:api_keys` in old User snapshots). Symmetric with the merge
  # above: merge gives fresh init for NEW slices, prune drops orphans
  # for REMOVED slices.
  defp prune_orphan_slices(state, kind_module) do
    declared =
      Ezagent.Kind.behaviors_of(kind_module)
      |> Enum.map(& &1.state_slice())
      |> MapSet.new()

    state
    |> Enum.filter(fn {key, _} -> MapSet.member?(declared, key) end)
    |> Map.new()
  end

  # Allen 2026-05-26 task #34 — for each Behavior on the Kind that
  # implements `reconcile_after_load/2`, hand it the current slice
  # value and let it sync with a DB projection (or any external
  # source of truth). Idempotent — the Behavior is expected to
  # union/dedupe so calling it on already-reconciled state is a
  # no-op.
  #
  # Why here, not in init_slice: init_slice runs BEFORE the merge,
  # so its DB-read result gets shadowed by `loaded_state`. The
  # reconcile step runs AFTER merge so it can amend the merged
  # output.
  #
  # Per `feedback_let_it_crash_no_workarounds`: a Behavior whose
  # reconcile raises propagates the crash — Kind.Server's
  # supervisor restarts the Kind. Persistent reconcile failure =
  # Kind stays down = correct (operator must fix the DB).
  defp reconcile_after_load_behaviors(state, %URI{} = uri, kind_module) do
    Enum.reduce(Ezagent.Kind.behaviors_of(kind_module), state, fn behavior, acc ->
      slice_key = behavior.state_slice()
      slice_value = Map.get(acc, slice_key)

      if function_exported?(behavior, :reconcile_after_load, 2) and not is_nil(slice_value) do
        reconciled = behavior.reconcile_after_load(uri, slice_value)
        Map.put(acc, slice_key, reconciled)
      else
        acc
      end
    end)
  end

  defp reconcile_after_load_behaviors(state, uri_str, kind_module) when is_binary(uri_str) do
    # SPEC 2026-05-27-uri-canonicalization §B4 — snapshot reload routes
    # URI strings through the canonical chokepoint; let-it-crash on
    # malformed (supervisor restarts the Kind, operator sees the error).
    uri = Ezagent.URI.new!(uri_str)
    reconcile_after_load_behaviors(state, uri, kind_module)
  end

  defp fetch_snapshot(uri_str, kind_module) do
    case KindSnapshot.get(uri_str) do
      nil ->
        :error

      row ->
        with :ok <- check_version(row, kind_module),
             {:ok, state} <- KindSnapshot.decode_state(row) do
          {:ok, state}
        end
    end
  end

  defp check_version(row, kind_module) do
    declared = snapshot_version_of(kind_module)
    stored = row.version || 0

    cond do
      stored == declared ->
        :ok

      stored < declared ->
        # Phase 4 v1: per Spec 04 §2.G, accept fail-loud. Future Phase 5
        # can call Behavior.upgrade_slice/3 here.
        {:error, {:snapshot_version_too_old, stored, declared}}

      stored > declared ->
        # Newer snapshot vs older code = corruption risk; refuse.
        {:error, {:snapshot_version_too_new, stored, declared}}
    end
  end

  defp snapshot_version_of(kind_module) do
    if function_exported?(kind_module, :snapshot_version, 0) do
      kind_module.snapshot_version()
    else
      0
    end
  end

  @doc """
  Persist the new state per policy. No-op for `:ephemeral` / `:external`
  / unchanged slice.

  Returns `:ok` even on write failure (logged + telemetry); the caller
  (Kind.Server) treats the in-memory slice as the truth.

  **For callers that need to know whether durable persistence
  actually happened, use `commit/4` instead** (see codex PR-N1
  round-3 HIGH-1 fix below).
  """
  @spec maybe_save(URI.t() | String.t(), module(), %{atom() => map()}, %{atom() => map()}) :: :ok
  def maybe_save(uri, kind_module, old_state, new_state) do
    _ = commit(uri, kind_module, old_state, new_state)
    :ok
  end

  @doc """
  Codex PR-N1 round-3 HIGH-1 fix — `maybe_save/4` lies (returns `:ok`
  on write failure), so callers that need to know "is the state
  durable yet?" must use this.

  Return shape:

  - `:ok` — durable write succeeded, slice survives a restart
  - `:not_durable` — policy doesn't require a durable write here
    (ephemeral / external / unchanged / periodic-deferred). Callers
    that want to emit post-commit notifications CAN emit on this
    because there's no durability promise being made
  - `{:error, reason}` — durable write was attempted and FAILED.
    Callers MUST NOT emit downstream "your state changed" signals
    because the GenServer holds state that won't survive crash

  `Kind.Server.commit_and_notify/3` consumes this to gate
  `SliceChange.emit/1`.
  """
  @spec commit(URI.t() | String.t(), module(), %{atom() => map()}, %{atom() => map()}) ::
          :ok | :not_durable | {:error, term()}
  def commit(uri, kind_module, old_state, new_state) do
    case Ezagent.Kind.persistence_of(kind_module) do
      :ephemeral ->
        :not_durable

      :external ->
        :not_durable

      :on_terminate ->
        # Only written via save_now/3 in terminate; not in dispatch hot path.
        :not_durable

      {:snapshot, :on_change} ->
        # Lifecycle Phase A (SPEC 2026-05-29 §0.1 + §10-R2) — compare the
        # PERSISTABLE view only. A `{:set_transient, ...}` effect mutates
        # a Lifecycle slice's `:transients` sub-key, which is NEVER
        # snapshotted; a transient-only change must therefore NOT trigger
        # a durable write (the stripped views are equal). Legacy slices
        # (no `:transients` sub-key) are unaffected by the strip.
        if strip_transients(old_state) == strip_transients(new_state) do
          :not_durable
        else
          # save_now/3 is now strict (issue #342, Allen 2026-05-25 —
          # rescue removed) so its return is exactly what `commit/4`'s
          # caller needs to gate the SliceChange emit on.
          save_now(uri, kind_module, new_state)
        end

      {:snapshot, :periodic, _ms} ->
        # Async via Writer. Timer in Server fires save_now via Writer cast.
        # commit/4 itself doesn't block on the timer.
        :not_durable
    end
  end

  @doc """
  Synchronous write — used by `:on_change`, `:on_terminate`, and the
  Writer's flush path.

  Returns `:ok` on success, `{:error, reason}` on changeset failure.
  Raises on infrastructure failures (`DBConnection.ConnectionError`,
  `Exqlite.Error`, etc.) — the caller decides whether to rescue.

  ## Why no internal rescue (let-it-crash; issue #342, Allen 2026-05-25)

  Previously `save_now/3` wrapped `KindSnapshot.upsert/5` in
  `try/rescue` and silently returned `:ok` on DB errors (logged +
  `:failed` telemetry only). This was a workaround that violated the
  let-it-crash discipline: every layer above this point trusted the
  `:ok` and reported success to its caller, so a mix-task `agent.create`
  could return success to the operator while no DB row was written.

  The fix: surface the failure naturally. Callers that genuinely need
  best-effort semantics (e.g. background `Writer` flushes, `terminate/2`
  shutdowns, periodic ticks) wrap the call in `try/rescue` at THEIR
  boundary, where the decision is local and explicit. Callers that
  need durability (e.g. `Kind.Server.init/1`'s
  `persist_initial_snapshot/3`, the dispatch reply path) propagate the
  error to their own caller.

  Phase 9 PR-6 (SPEC v3 §7) + SPEC #324 rev 3 (Allen 2026-05-25) —
  derives `workspace_uri` for the snapshot row from the Kind URI. For
  cross-cutting URIs (`system://`, `template://`, `resource://`) which
  return `:any` from the derivation helper, inlines the literal
  `"workspace://system"` (the admin workspace, structural sink for
  system-tier state — these snapshots own no per-tenant data, so
  landing in admin is structurally correct).
  """
  @spec save_now(URI.t() | String.t(), module(), %{atom() => map()}, keyword()) ::
          :ok | {:error, term()}
  def save_now(uri, kind_module, state, opts \\ []) do
    uri_str = uri_to_str(uri)
    kind_type_str = Atom.to_string(kind_module.type_name())
    version = snapshot_version_of(kind_module)
    # Lifecycle Phase A (SPEC 2026-05-29 §0.1 + §10-R2) — strip every
    # Lifecycle slice's `:transients` sub-key BEFORE serialization.
    # `transients` (PIDs / refs / ETS handles / ports / monitor refs)
    # has no serialization path by construction: it is dropped here and
    # rebuilt by `activate/2` on the next start. This is the mechanism
    # that kills the cold-restart bug class — a transient CANNOT be
    # accidentally persisted because the only serialization site strips
    # it. Legacy (non-Lifecycle) slices have no `:transients` sub-key
    # and pass through unchanged.
    binary = :erlang.term_to_binary(strip_transients(state))
    workspace_uri_str = derive_workspace_uri(uri)

    # Lifecycle Phase A (SPEC §9 OQ-1, F3) — when the caller is the
    # initial-persist of a Lifecycle Kind, set the `ever_created` marker
    # in the SAME upsert as the state binary so the marker is atomic with
    # the snapshot it gates. No separate fire-and-forget write that a
    # crash could land between.
    upsert_opts =
      case Keyword.get(opts, :mark_ever_created, false) do
        true -> [mark_ever_created: true]
        _ -> []
      end

    case KindSnapshot.upsert(uri_str, kind_type_str, binary, version, workspace_uri_str, upsert_opts) do
      {:ok, _row} ->
        :telemetry.execute(
          [:ezagent, :persistence, :written],
          %{bytes: byte_size(binary)},
          %{uri: uri_str, kind_type: kind_type_str, version: version}
        )

        :ok

      {:error, reason} ->
        Logger.warning("Ezagent.Kind.Snapshot: save failed for #{uri_str}: #{inspect(reason)}")

        :telemetry.execute(
          [:ezagent, :persistence, :failed],
          %{},
          %{uri: uri_str, kind_type: kind_type_str, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  # Phase 9 PR-6 + SPEC #324 rev 3 (Allen 2026-05-25) + r1 codex
  # tightening — derive workspace string for snapshot row.
  #
  # Rules:
  # 1. `entity://` / `workspace://` / `session://` — derive workspace
  #    structurally via `workspace_uri_for/1` (returns `{:ok, ws}`).
  # 2. `system://` — admin-tier snapshot; inline `"workspace://system"`
  #    literal with comment. This is the ONLY cross-cutting scheme
  #    allowed to fall through to system.
  # 3. Anything else (`template://`, `resource://`, unknown / malformed
  #    schemes) — RAISE. r1 codex caught: lumping these under the
  #    "cross-cutting" fallback reintroduces the silent-default bug
  #    class Allen deleted (a future tenant-scoped URI would be
  #    snapshotted into the hidden system workspace, invisible to
  #    tenant reads + visible to admin paths).
  #
  # Inlined literal (not via a global helper) per SPEC #324 rev 3: a
  # shared `default_workspace_uri/0` was the silent fallback Allen
  # deleted.
  defp derive_workspace_uri(uri) do
    parsed =
      case uri do
        %URI{} = u -> u
        s when is_binary(s) -> Ezagent.URI.new!(s)
      end

    case Ezagent.Persistence.workspace_uri_for(parsed) do
      {:ok, ws} ->
        ws

      {:error, :no_workspace} ->
        # `workspace_uri_for/1` returns `:no_workspace` for any scheme
        # whose `Capability.workspace_of/1` is `:any`. We accept only
        # `system://` here — every other unknown/malformed scheme
        # raises, so the operator sees the structural error instead
        # of silent admin-workspace pollution.
        case parsed do
          %URI{scheme: "system"} ->
            # System-tier snapshot — admin's workspace is the
            # structural sink (SPEC v3 §13.1). Inlined literal.
            "workspace://system"

          other ->
            raise ArgumentError,
                  "Ezagent.Kind.Snapshot.derive_workspace_uri/1: cannot derive " <>
                    "workspace for URI=#{inspect(other)}. Per SPEC #324 rev 3, only " <>
                    "the 4 per-tenant schemes (entity/workspace/session derive " <>
                    "structurally) and `system://` (lands in workspace://system) " <>
                    "are accepted. Adding this URI to the snapshot path requires " <>
                    "either making its scheme workspace-aware or explicitly " <>
                    "declaring it system-scope at the call site."
        end
    end
  end

  # ---------------------------------------------------------------------
  # Internals

  @doc """
  Lifecycle Phase A (SPEC 2026-05-29 §0.1 + §10-R2) — return the
  PERSISTABLE view of a Kind's `slice_state` map: every Lifecycle
  slice's `:transients` sub-key is dropped.

  A Lifecycle slice has the two-container shape `%{state: map(),
  transients: map()}` (emitted by `use Ezagent.Lifecycle`). `transients`
  holds PIDs / refs / ETS handles / ports / monitor refs that MUST NOT
  be serialized — they are rebuilt by `activate/2` on every start. This
  function is the single chokepoint that enforces "only `state` is
  snapshotted": it runs at the serialize boundary (`save_now/3`) and in
  the `:on_change` dirty-check (`commit/4`).

  Legacy (non-Lifecycle) slices do NOT carry a `:transients` sub-key, so
  they pass through structurally unchanged — the strip is a no-op for
  them. The detection is purely structural (a map slice carrying a
  `:transients` key), so no engine/Behavior coupling is introduced.
  """
  @spec strip_transients(%{atom() => term()}) :: %{atom() => term()}
  def strip_transients(slice_state) when is_map(slice_state) do
    Map.new(slice_state, fn {slice_key, slice} ->
      {slice_key, strip_one_slice(slice)}
    end)
  end

  defp strip_one_slice(%{transients: _} = slice) when is_map(slice) do
    Map.delete(slice, :transients)
  end

  defp strip_one_slice(other), do: other

  defp init_fresh(kind_module, args) do
    Ezagent.Kind.behaviors_of(kind_module)
    |> Enum.map(fn behavior ->
      {behavior.state_slice(), behavior.init_slice(args)}
    end)
    |> Map.new()
  end

  @doc """
  SPEC 2026-05-27-uri-canonicalization §9.2.1 (OQ-4 option b) — recursive
  walker that re-canonicalizes every `%URI{}` embedded in a decoded
  snapshot state.

  Pre-migration snapshots written via `:erlang.term_to_binary/1` may
  contain `URI.parse`-built structs (`:authority` populated). Replaying
  such a snapshot would surface URIs that fail struct-equality with
  their canonical peers (the bug class described in SPEC §1.1).

  ## Clause order is load-bearing

  1. `%URI{}` first — `%URI{}` IS a struct; without this clause, the
     `%_{} = struct_` generic-struct clause would catch it first and
     destructure to a plain map.
  2. Custom struct (`%_{} = struct_`) — destructure via
     `Map.from_struct/1`, walk the map, re-struct via `struct/2` so
     the original struct shape is preserved.
  3. Map (`is_map/1`) — walk BOTH keys and values; URIs can appear as
     map keys (rare but valid).
  4. List (`is_list/1`) — walk elementwise.
  5. Tuple (`is_tuple/1`) — convert to list, walk, convert back.
  6. Fallthrough — atoms, numbers, binaries, pids — unchanged.

  The `%URI{}` clause routes through `Ezagent.URI.new!/1` (the
  canonical chokepoint). Non-Ezagent schemes (e.g. external `http://`
  URLs that snuck into a slice via legacy code) fall back to strict
  stdlib `URI.new/1` per the §3.7 dual-fallback contract. Outright
  failure leaves the original struct unchanged (let-it-crash applies
  to dispatch, not to passive walk-and-rewrite).
  """
  @spec canonicalize_uris(term()) :: term()
  def canonicalize_uris(%URI{} = uri) do
    s = URI.to_string(uri)

    try do
      Ezagent.URI.new!(s)
    rescue
      # External (non-Ezagent) scheme — §3.7 fallback. Re-parse via
      # strict URI.new/1 so authority is RFC-3986-normalized; leave
      # the original on outright parse failure (passive walker —
      # downstream let-it-crash governs the dispatch path, not this).
      ArgumentError ->
        case URI.new(s) do # uri-canonical-allow: §3.7 external-URI fallback (non-Ezagent scheme — SchemeRegistry rejects, this re-canonicalizes via strict RFC 3986)
          {:ok, canonical} -> canonical
          _ -> uri
        end
    end
  end

  def canonicalize_uris(%_{} = struct_) do
    # Custom struct — destructure to map (drop :__struct__), walk,
    # re-struct. Preserves the original struct module identity.
    mod = struct_.__struct__

    struct_
    |> Map.from_struct()
    |> canonicalize_uris()
    |> then(&struct(mod, &1))
  end

  def canonicalize_uris(state) when is_map(state) do
    Map.new(state, fn {k, v} -> {canonicalize_uris(k), canonicalize_uris(v)} end)
  end

  def canonicalize_uris(state) when is_list(state) do
    Enum.map(state, &canonicalize_uris/1)
  end

  def canonicalize_uris(state) when is_tuple(state) do
    state
    |> Tuple.to_list()
    |> Enum.map(&canonicalize_uris/1)
    |> List.to_tuple()
  end

  def canonicalize_uris(other), do: other

  defp emit_restored(uri_str, state) do
    :telemetry.execute(
      [:ezagent, :persistence, :restored],
      %{slices: map_size(state)},
      %{uri: uri_str}
    )
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end
