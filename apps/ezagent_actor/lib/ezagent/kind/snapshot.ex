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

  Per Spec 04 Q2 default: `:on_change` is **sync** (~1ms local DB write;
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
        init_fresh_first_spawn(kind_module, args)

      :external ->
        # Plugin author's init_slice/1 reads from foreign system; don't touch DB.
        init_fresh_first_spawn(kind_module, args)

      :on_terminate ->
        load_with_fallback(uri, kind_module, args)

      {:snapshot, _strategy} ->
        load_with_fallback(uri, kind_module, args)
    end
  end

  @doc """
  `load_or_init/3` wrapped so the synchronous snapshot READ (a `Repo.one`
  via `fetch_snapshot/2`) is as resilient as the WRITE (`save_now/4`).

  Returns `{:ok, slice_state}` or `{:error, reason}`. #108: a
  globally-supervised Kind whose spawn lands AFTER the ExUnit sandbox owner
  exited queries a pool reverted to `:manual` → `DBConnection.OwnershipError`
  (raised) or a linked-connection death (`:exit`). `save_now/4` already catches
  BOTH at its boundary; mirror that here so `Kind.Server.init/1` can return a
  clean `{:stop, ...}` instead of an uncaught init crash. NO fresh-state
  fallback (that would risk the blocker-#2 cold-restart wipe) — the caller
  let-it-crashes.
  """
  @spec safe_load_or_init(URI.t() | String.t(), module(), map()) ::
          {:ok, %{atom() => map()}} | {:error, term()}
  def safe_load_or_init(uri, kind_module, args) do
    {:ok, load_or_init(uri, kind_module, args)}
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp load_with_fallback(uri, kind_module, args) do
    uri_str = uri_to_str(uri)
    receiver_uri = Ezagent.URI.new!(uri_str)

    # P1 (SPEC §3.1, codex CRITICAL finding 1): fetch the persisted row FIRST.
    # We do NOT compute `init_fresh` up-front any more — running init_set /
    # validate_closure! / init_slice from SPAWN ARGS before the persisted
    # `:kind_base` is read would let a fallback-args set create out-of-set
    # slices (or crash a valid persisted instance with an unclosed fallback
    # set) on every restart.
    case fetch_snapshot(uri_str, kind_module) do
      :not_found ->
        # TRUE first spawn — no persisted row. The set is driven by spawn args
        # (init_set/2), closure-validated, and ONLY that set's slices are
        # created. This is the §3.1 first-spawn guard.
        init_fresh_first_spawn(kind_module, args)

      {:ok, loaded_state} ->
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
        # keys for Behaviors the Kind no longer declares. Pruning at
        # load drops the orphan from the live state immediately; the
        # next `:on_change` persistence then writes the pruned shape
        # back to disk.
        #
        # Allen 2026-05-26 task #34 — also RECONCILE each Behavior
        # with its DB projection (if it declares
        # `reconcile_after_load/2`). Idempotent for normal-path callers.
        canonicalized = canonicalize_uris(loaded_state)

        # P1 LEGACY-SNAPSHOT MIGRATION (codex CRITICAL — data-loss hole). A
        # snapshot WRITTEN BEFORE P1 has NO `:kind_base` slice (KindBase did
        # not exist). Seed `:kind_base` with the LEGACY SENTINEL `nil`
        # — INDEPENDENT of the reload args — BEFORE deriving the effective set,
        # so a pre-P1 instance behaves exactly like a legacy static Kind
        # (sentinel nil → full DECLARED list) and the reload args can NEVER
        # re-drive its set. Without this, an args-driven `init_fresh_for_set`
        # could persist a `:kind_base` recording `args[:behaviors]`; the very
        # NEXT reload would read that captured set back and `prune_orphan_slices`
        # would DROP every previously-persisted declared slice not in those
        # args — silent data loss for existing prod sessions. A post-P1 row
        # (already has `:kind_base`) is returned unchanged.
        canonicalized = seed_legacy_kind_base(canonicalized)

        # P1 reload scoping (codex finding 1): the effective set is derived
        # from the PERSISTED `:kind_base` slice (now ALWAYS present — either
        # the real post-P1 captured value, or the legacy sentinel seeded just
        # above), NOT the spawn args. Validate THAT set, then build the
        # `fresh` baseline by init_slice'ing ONLY that set's members (NOT the
        # module superset, NOT a spawn-args set). For members the snapshot
        # already owns, the fresh value is immediately overwritten by the
        # Map.merge(loaded) below (loaded wins — same as the original code);
        # for newly-added behaviors the fresh value is kept (the Q5 contract).
        effective = Ezagent.Kind.BehaviorSet.effective_set(kind_module, canonicalized)
        _ = Ezagent.Kind.BehaviorSet.validate_closure!(effective)
        fresh = init_fresh_for_set(effective, args)

        rehydrated =
          fresh
          |> Map.merge(coerce_loaded_to_fresh_shape(fresh, canonicalized))
          |> prune_orphan_slices(kind_module)
          |> reconcile_after_load_behaviors(uri, kind_module)
          |> verify_snapshot_caps(receiver_uri)

        emit_restored(uri_str, rehydrated)
        rehydrated

      {:error, reason} ->
        # PR-4 (blocker #2). A row EXISTS but is unloadable (version mismatch /
        # decode failure). Returning `fresh` here lets `Kind.Server.init/1`
        # persist EMPTY over the good row — the observed 256KB→91b cold-restart
        # wipe (members/legends/working-copy lost). Fail loud instead: the
        # durable state must NEVER be silently destroyed. `check_version`
        # already documents Phase-4 fail-loud intent; this enforces it at the
        # load layer. The Kind's supervisor surfaces the crash; the operator
        # fixes the version/data (a future Phase-5 `upgrade_slice/3` migrates
        # version-too-old in place instead of crashing).
        raise "Ezagent.Kind.Snapshot: refusing to initialize #{uri_str} as fresh " <>
                "over an EXISTING but unloadable snapshot (#{inspect(reason)}) — " <>
                "this would wipe durable state on the initial persist (blocker #2)"
    end
  end

  # Allen 2026-05-26 (codex HIGH-2) — drop any slice keys not declared
  # by the Kind's current `behaviors/0`. Keys to drop come from snapshot
  # state that survived a Behavior removal (e.g. ApiKeys-to-Agent flip
  # left `:api_keys` in old User snapshots). Symmetric with the merge
  # above: merge gives fresh init for NEW slices, prune drops orphans
  # for REMOVED slices.
  defp prune_orphan_slices(state, kind_module) do
    # P1 (SPEC §3.1, E6) — keep only the INSTANCE slice-bearing set's slices
    # (defense-in-depth on reload over the persisted `:kind_base`-derived set),
    # not the module's declared superset. `materialized_set/2` excludes universal
    # behaviors (Manage — dispatch-only, no slice); `:kind_base` is in the set
    # (KindBase is slice-bearing) but we also keep it explicitly as belt-and-
    # suspenders since it carries the instance set.
    kept =
      Ezagent.Kind.BehaviorSet.materialized_set(kind_module, state)
      |> Enum.map(& &1.state_slice())
      |> MapSet.new()
      # KindBase's own slice must never be pruned — it carries the set.
      |> MapSet.put(:kind_base)

    state
    |> Enum.filter(fn {key, _} -> MapSet.member?(kept, key) end)
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
    # P1 (SPEC §3.1, E7) — iterate the INSTANCE slice-bearing set
    # (`materialized_set/2`, excludes the slice-less universal Manage), not the
    # module superset, so an out-of-set behavior's `reconcile_after_load` never
    # runs.
    Enum.reduce(Ezagent.Kind.BehaviorSet.materialized_set(kind_module, state), state, fn behavior,
                                                                                         acc ->
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

  # Returns:
  #   * `{:ok, state}`  — row present and loaded
  #   * `:not_found`    — NO row (genuinely new Kind → fresh init is correct)
  #   * `{:error, _}`   — row PRESENT but unloadable (version mismatch / decode
  #                       failure). The caller MUST NOT reset to fresh: doing so
  #                       + the unconditional initial persist would overwrite the
  #                       good row with empty (the cold-restart wipe, blocker #2).
  defp fetch_snapshot(uri_str, kind_module) do
    case KindSnapshot.get(uri_str) do
      nil ->
        :not_found

      row ->
        with :ok <- check_version(row, kind_module),
             {:ok, state} <- KindSnapshot.decode_state(row) do
          {:ok, state}
        else
          {:error, reason} -> {:error, reason}
          :error -> {:error, :decode_failed}
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

  @commit_doc """
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
  # COMPILE-TIME test gate (codex P2.5c impl MEDIUM): the force-fail seam is
  # compiled IN only for `MIX_ENV=test`. In a dev/prod/release build this is a
  # literal `false`, so `maybe_forced_commit_failure/1` is a dead `:proceed`
  # branch that NEVER reads the app env — the seam is provably unreachable
  # outside tests, regardless of any stray `:p2_5c_force_commit_failure_uris`
  # config or runtime set.
  @p2_5c_commit_failure_seam_enabled Mix.env() == :test

  if @p2_5c_commit_failure_seam_enabled do
    @doc @commit_doc
    def commit(uri, kind_module, old_state, new_state) do
      # P2.5c TEST-ONLY force-fail seam (codex-reviewed). Lets the
      # parent-commit-rollback gate (and the dispatch_after_commit unit test)
      # deterministically force a durable-commit failure for ONE specific URI
      # mid-test, without a real DB outage. Consulted ONLY when the app env
      # `:ezagent_core, :p2_5c_force_commit_failure_uris` is set (a MapSet /
      # list of URI strings) — `nil` in dev/prod, so this is a pure no-op with
      # zero behavior change off the test path. When the dispatching URI is in
      # the set, `commit/4` returns `{:error, _}` exactly as a genuine
      # `save_now` failure would (issue #342), so `Kind.Server` keeps the slice
      # un-advanced AND skips the deferred post-commit dispatches.
      case maybe_forced_commit_failure(uri) do
        :proceed -> do_commit(uri, kind_module, old_state, new_state)
        {:error, _} = err -> err
      end
    end

    defp maybe_forced_commit_failure(uri) do
      case Application.get_env(:ezagent_core, :p2_5c_force_commit_failure_uris) do
        nil ->
          :proceed

        uris ->
          uri_str = uri_to_str(uri)

          if uri_str in uris do
            {:error, {:p2_5c_forced_commit_failure, uri_str}}
          else
            :proceed
          end
      end
    end
  else
    @doc @commit_doc
    def commit(uri, kind_module, old_state, new_state) do
      do_commit(uri, kind_module, old_state, new_state)
    end
  end

  defp do_commit(uri, kind_module, old_state, new_state) do
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

    case KindSnapshot.upsert(
           uri_str,
           kind_type_str,
           binary,
           version,
           workspace_uri_str,
           upsert_opts
         ) do
      {:ok, _row} ->
        :telemetry.execute(
          [:ezagent, :persistence, :written],
          %{bytes: byte_size(binary)},
          %{uri: uri_str, kind_type: kind_type_str, version: version}
        )

        maybe_dual_write_identity_caps(uri_str, state)

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

  # #189 PR-1 dual-write (identity-plane cutover step 1, ADDITIVE): every
  # durable snapshot write through THIS chokepoint (init persist, post-init
  # commit, on-change dispatch commit, Writer flush, terminate) mirrors its
  # `:identity` slice into the unified identity-caps store (config-injected
  # via `:ezagent_actor, :identity_caps_store` — no compile-time reference
  # from the actor layer to the domain store). The domain store module
  # never raises (best-effort write-shadow; failures are logged at :error
  # there) and decides what to skip (user URIs mirror via `users.caps_json`;
  # slices without a caps set are ignored).
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

    case persistence().workspace_uri_for(parsed) do
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
            # structural sink (SPEC v3 §13.1).
            Ezagent.URI.workspace(:system) |> URI.to_string()

          other ->
            raise ArgumentError,
                  "Ezagent.Kind.Snapshot.derive_workspace_uri/1: cannot derive " <>
                    "workspace for URI=#{inspect(other)}. Per SPEC #324 rev 3, only " <>
                    "the 4 per-tenant schemes (entity/workspace/session derive " <>
                    "structurally) and system scope (lands in the system workspace) " <>
                    "are accepted. Adding this URI to the snapshot path requires " <>
                    "either making its scheme workspace-aware or explicitly " <>
                    "declaring it system-scope at the call site."
        end
    end
  end

  # ---------------------------------------------------------------------
  # Internals

  # C5 §3.4 PersistencePort — workspace derivation goes through the
  # config-resolved port, never the literal `Ezagent.Persistence` spine.
  # Wired at core boot (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.PersistenceAdapter`.
  defp persistence, do: Application.fetch_env!(:ezagent_actor, :persistence)

  # C5 §3.4 AuthorityPort — persisted-cap verification goes through the
  # config-resolved port, never the literal `Ezagent.Cap` spine. Wired at
  # core boot (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.AuthorityAdapter`.
  defp authority, do: Application.fetch_env!(:ezagent_actor, :authority)

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

  # T4 (Lifecycle Phase B foundation) — coerce a LEGACY FLAT snapshot slice
  # into the two-container shape when the Behavior has since converted to
  # `use Ezagent.Lifecycle`.
  #
  # The hazard: `fresh` (from `init_fresh/2`) carries a converted
  # Behavior's slice as `%{state: %{}, transients: %{}}`, but a
  # pre-migration `kind_snapshots` row holds that slice as a FLAT map
  # (persistent + transient mixed, the old shape). The subsequent
  # `Map.merge(fresh, loaded)` lets the flat slice SHADOW the two-container
  # fresh value, so the live slice becomes flat — and a converted Kind's
  # `__run_activate__` (which matches `%{state: st}`) crashes on boot.
  #
  # We detect the per-slice-key mismatch STRUCTURALLY (fresh is
  # two-container `%{state: _, transients: _}` while the loaded value is a
  # flat map with NO `:state` key) and coerce the loaded flat map to
  # `%{state: flat, transients: %{}}` on read. The persistent data
  # rehydrates under `:state`; `transients` starts empty and `activate/2`
  # rebuilds it on this same start — exactly the cold-load contract.
  #
  # This does NOT replace the R-2 WIPE (the prod cutover plan stays a clean
  # snapshot wipe). It is the safety net that keeps a stray flat row from
  # CRASHING a converted Kind — reducing reliance on a perfect test-DB
  # wipe and making the eventual prod cutover safer. A loaded value that is
  # ALREADY two-container (a post-migration row) or whose fresh peer is
  # legacy-flat (an un-migrated Behavior) passes through unchanged.
  @spec coerce_loaded_to_fresh_shape(%{atom() => term()}, %{atom() => term()}) ::
          %{atom() => term()}
  defp coerce_loaded_to_fresh_shape(fresh, loaded) do
    Map.new(loaded, fn {slice_key, loaded_slice} ->
      {slice_key, coerce_one_slice(Map.get(fresh, slice_key), loaded_slice)}
    end)
  end

  # Fresh is two-container, loaded is flat (no `:state`) → wrap the flat
  # persistent map; `transients` rebuilt by `activate/2`.
  defp coerce_one_slice(%{state: _, transients: _}, loaded_slice)
       when is_map(loaded_slice) and not is_map_key(loaded_slice, :state) do
    %{state: loaded_slice, transients: %{}}
  end

  # Any other combination (both two-container, both flat, fresh has no peer,
  # non-map loaded value) → unchanged.
  defp coerce_one_slice(_fresh_slice, loaded_slice), do: loaded_slice

  # Phase 3 S4 / I5 boundary #4: a capability re-entering the live Kind from
  # `kind_snapshots.state_binary` is verified before the decoded identity
  # slice becomes live, after fresh+loaded merge and reconciliation. Both the
  # pre-Lifecycle flat shape and the current two-container shape are accepted;
  # malformed or unverified entries fail closed by being omitted from the
  # loaded set.
  defp verify_snapshot_caps(
         %{identity: %{state: %{caps: caps} = inner} = slice} = state,
         receiver_uri
       ) do
    put_verified_snapshot_caps(state, {:lifecycle, slice, inner}, caps, receiver_uri)
  end

  defp verify_snapshot_caps(%{identity: %{caps: caps} = slice} = state, receiver_uri) do
    put_verified_snapshot_caps(state, {:flat, slice}, caps, receiver_uri)
  end

  defp verify_snapshot_caps(state, _receiver_uri), do: state

  defp put_verified_snapshot_caps(state, location, caps, receiver_uri) do
    verified = authority().verified_set(caps, receiver_uri)

    verified_slice =
      case location do
        {:lifecycle, slice, inner} -> %{slice | state: %{inner | caps: verified}}
        {:flat, slice} -> %{slice | caps: verified}
      end

    %{state | identity: verified_slice}
  end

  # P1 FIRST-spawn slice materialization. Reachable ONLY from
  # `load_with_fallback/3`'s `:not_found` branch and from `load_or_init/3`'s
  # no-DB `:ephemeral`/`:external` arms (first-spawn-every-time by
  # construction). Enumerates ONLY `BehaviorSet.init_set/2` (spawn-args subset
  # ∩ declared, + base behaviors) and FAILS LOUD on an unclosed set BEFORE any
  # init_slice/create runs or any slice is persisted (P1.1, codex CRITICAL).
  # `validate_closure!/1` returns the (unchanged) set on success so the pipe
  # continues; on a missing REQUIRED sibling it raises `UnclosedSetError` →
  # load_or_init → Kind.Server.init/1 returns `{:stop, …}` →
  # persist_initial_snapshot/3 is NEVER reached → no partial slice row lands.
  defp init_fresh_first_spawn(kind_module, args) do
    kind_module
    |> Ezagent.Kind.BehaviorSet.init_set(args)
    |> Ezagent.Kind.BehaviorSet.validate_closure!()
    |> init_fresh_for_set(args)
  end

  # P1 init_slice exactly `set` (already closure-validated by the caller). Used
  # on BOTH the first-spawn path (after init_set + validate) AND the reload
  # path (on the PERSISTED effective set). On reload, members the snapshot
  # already owns get a fresh value here that the caller's Map.merge(loaded)
  # immediately overwrites (loaded wins — identical to the original merge
  # semantics); newly-added behaviors keep their fresh value (the Q5 contract).
  # An out-of-set behavior is never in `set`, so its init_slice/create NEVER
  # runs — at first spawn OR on reload.
  #
  # BEHAVIOR-PRESERVING EXCLUSION (codex CRITICAL — universal-behavior policy).
  # `set` includes `BehaviorSet.base_behaviors/0` = `KindBase` +
  # `UniversalBehaviors.all/0` (Manage). `Manage` is DISPATCH-ONLY: it is
  # universal-by-construction, resolves via the registry fallback, its handlers
  # read NO slice (`handle_delete/2`/`handle_reconfigure/2` take `_ctx` only),
  # and pre-P1 it was NEVER in any Kind's `behaviors_of/0` so its `:manage`
  # slice was NEVER materialized or persisted. Materializing it now would (a)
  # add a vestigial `:manage` slice to EVERY instance's persisted shape (a
  # behavior change), and (b) run `Manage`'s Lifecycle `__init_slice__` →
  # `ever_created?` on every spawn. We therefore EXCLUDE universal behaviors
  # from slice materialization — they stay MEMBERS of `effective_set` (so the
  # E9 dispatch gate + membership semantics are unchanged) but get no slice.
  # `KindBase` IS materialized: it owns the persisted `:kind_base` slice that
  # carries the instance set (the whole point of P1).
  defp init_fresh_for_set(set, args) do
    universal = MapSet.new(Ezagent.UniversalBehaviors.all())

    set
    |> Enum.reject(&MapSet.member?(universal, &1))
    |> Enum.map(fn behavior -> {behavior.state_slice(), behavior.init_slice(args)} end)
    |> Map.new()
  end

  # P1 LEGACY-SNAPSHOT MIGRATION (codex CRITICAL — data-loss hole). Called on
  # the reload branch BEFORE deriving the effective set. A snapshot WRITTEN
  # BEFORE P1 has NO `:kind_base` slice (KindBase did not exist). Seed it with
  # the LEGACY SENTINEL `nil` — INDEPENDENT of the reload args — so:
  #
  #   * `effective_set/2` reads the seeded slice back via
  #     `KindBase.behaviors_in_slice/1` as the sentinel `nil` → the FULL
  #     DECLARED list, so NO previously-persisted declared slice is pruned;
  #   * the seeded slice carries the two-container shape KindBase persists, so
  #     the next `:on_change` save writes `%{behaviors: nil}` back, and every
  #     future reload re-reads sentinel nil — the legacy instance stays "full
  #     declared", arg-free, forever.
  #
  # A snapshot that ALREADY has `:kind_base` (written post-P1) is returned
  # UNCHANGED — its real captured value (a present list, including `[]`, or a
  # sentinel nil) drives the effective set. This is the deploy-safety
  # guarantee: reload args can NEVER re-drive a legacy instance's behavior set.
  defp seed_legacy_kind_base(loaded_state) do
    kind_base_key = Ezagent.ActionSet.KindBase.state_slice()

    if Map.has_key?(loaded_state, kind_base_key) do
      loaded_state
    else
      Map.put(loaded_state, kind_base_key, %{state: %{behaviors: nil}, transients: %{}})
    end
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
        # Non-Ezagent scheme: SchemeRegistry rejects, then strict RFC 3986 recanonicalizes.
        case Ezagent.URI.strict_external_new(s) do
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
