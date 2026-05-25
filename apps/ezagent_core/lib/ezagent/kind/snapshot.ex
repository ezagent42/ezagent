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
    case kind_module.persistence() do
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
        # Merge so newly-added Behaviors get fresh init values (Q5).
        Map.merge(fresh, loaded_state)

      :error ->
        fresh

      {:error, reason} ->
        Logger.warning(
          "Ezagent.Kind.Snapshot: load failed for #{uri_str}: #{inspect(reason)}; using fresh init"
        )

        fresh
    end
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
    case kind_module.persistence() do
      :ephemeral ->
        :not_durable

      :external ->
        :not_durable

      :on_terminate ->
        # Only written via save_now/3 in terminate; not in dispatch hot path.
        :not_durable

      {:snapshot, :on_change} ->
        if old_state == new_state do
          :not_durable
        else
          # save_now/3 returns `:ok` regardless of write success (it
          # logs + emits :failed telemetry on error); we re-derive
          # the strict result by re-attempting via a strict variant
          # to avoid breaking existing callers of save_now/3.
          save_now_strict(uri, kind_module, new_state)
        end

      {:snapshot, :periodic, _ms} ->
        # Async via Writer. Timer in Server fires save_now via Writer cast.
        # commit/4 itself doesn't block on the timer.
        :not_durable
    end
  end

  # Strict variant — returns the real outcome so `commit/4` can
  # tell `Kind.Server` whether to emit.
  defp save_now_strict(uri, kind_module, state) do
    uri_str = uri_to_str(uri)
    kind_type_str = Atom.to_string(kind_module.type_name())
    version = snapshot_version_of(kind_module)
    binary = :erlang.term_to_binary(state)
    workspace_uri_str = derive_workspace_uri(uri)

    try do
      KindSnapshot.upsert(uri_str, kind_type_str, binary, version, workspace_uri_str)
    rescue
      e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
        {:error, e}
    end
    |> case do
      {:ok, _row} ->
        :telemetry.execute(
          [:ezagent, :persistence, :written],
          %{bytes: byte_size(binary)},
          %{uri: uri_str, kind_type: kind_type_str, version: version}
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Ezagent.Kind.Snapshot.commit/4: save failed for #{uri_str}: #{inspect(reason)}"
        )

        :telemetry.execute(
          [:ezagent, :persistence, :failed],
          %{},
          %{uri: uri_str, kind_type: kind_type_str, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Synchronous write — used by `:on_change`, `:on_terminate`, and the
  Writer's flush path. Logs + emits `:failed` telemetry on error.

  Phase 9 PR-6 (SPEC v3 §7) + SPEC #324 rev 3 (Allen 2026-05-25) —
  derives `workspace_uri` for the snapshot row from the Kind URI. For
  cross-cutting URIs (`system://`, `template://`, `resource://`) which
  return `:any` from the derivation helper, inlines the literal
  `"workspace://system"` (the admin workspace, structural sink for
  system-tier state — these snapshots own no per-tenant data, so
  landing in admin is structurally correct). No global default helper:
  inline literals at the write site so the silent-fallback bug class
  Allen deleted on 2026-05-25 cannot regress.
  """
  @spec save_now(URI.t() | String.t(), module(), %{atom() => map()}) :: :ok
  def save_now(uri, kind_module, state) do
    uri_str = uri_to_str(uri)
    kind_type_str = Atom.to_string(kind_module.type_name())
    version = snapshot_version_of(kind_module)
    binary = :erlang.term_to_binary(state)
    workspace_uri_str = derive_workspace_uri(uri)

    # `KindSnapshot.upsert/5` returns `{:error, _}` for changeset
    # failures, but `Repo.get`/`Repo.insert` can also *raise*
    # (`DBConnection.ConnectionError` / `DBConnection.OwnershipError`)
    # when the connection pool is unavailable. The moduledoc contract
    # is "write failure does NOT crash the Kind" — so we rescue the
    # raised case too and treat it identically to a returned error.
    # Without this, an `:on_change` Kind whose snapshot write hits a
    # pool error (notably the boot-time Session under the ExUnit SQL
    # Sandbox when a prior test's owner has exited) would crash mid
    # `handle_cast`. Phase 9 follow-up — Allen V1 acceptance 2026-05-22.
    try do
      KindSnapshot.upsert(uri_str, kind_type_str, binary, version, workspace_uri_str)
    rescue
      e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
        {:error, e}
    end
    |> case do
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

        :ok
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
        s when is_binary(s) -> URI.parse(s)
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

  defp init_fresh(kind_module, args) do
    kind_module.behaviors()
    |> Enum.map(fn behavior ->
      {behavior.state_slice(), behavior.init_slice(args)}
    end)
    |> Map.new()
  end

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
