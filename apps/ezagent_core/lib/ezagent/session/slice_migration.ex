defmodule Ezagent.Session.SliceMigration do
  @moduledoc """
  chat→session rename (Allen 2026-06-12, NO back-compat) — rename the
  top-level `:chat` state-slice key to `:session` on every persisted session
  `kind_snapshots` row.

  ## Why this exists

  The internal "Chat" Behavior was renamed to `Ezagent.Behavior.Session`. Its
  `state_slice/0` now AUTO-DERIVES to `:session` (was the explicit `:chat`
  override). A snapshot persisted under the OLD code carries its session state
  under the top-level `:chat` key; the NEW code reads/writes `:session`. There
  is NO dual-read shim — so any `:chat`-keyed row must be rewritten to
  `:session` BEFORE the new code serves it (ordered cutover; see "Deploy
  ordering" below).

  Fresh test/docker snapshots are written with `:session` from birth (the new
  `Behavior.Session` uses `:session`), so the TEST SUITE passes WITHOUT running
  this migration — the migration is the PRODUCTION cutover path only.

  ## Deploy ordering (ordered cutover — no back-compat dual-read)

  Mirrors the SPEC 2026-05-29 §R10-4 snapshot-cutover discipline:

      1. STOP all nodes (the old `:chat`-slice code must not be writing).
      2. Deploy the new code (uses `:session`) but DO NOT START serving yet.
      3. Run `mix ezagent.session.migrate_slice` against the DB → every
         `:chat`-keyed session row becomes `:session`-keyed.
      4. Confirm `mix ezagent.session.migrate_slice --gate` reports 0
         remaining `:chat`-keyed rows.
      5. START the new nodes. `create`/`activate` see `:session` slices.

  A new-code node MUST NOT start against a DB holding `:chat`-keyed rows: the
  `:session`-reading `Behavior.Session` would default the slice to `%{}`
  (members / owner_uri / working-copy lost) and the orphan `:chat` slice would
  be pruned at load (`Snapshot.prune_orphan_slices/2`).

  ## Migration boundary

  TEST / sandbox DB only here. The module reads + rewrites `kind_snapshots`
  rows via a direct `Ezagent.Ecto.KindSnapshot.upsert/5` (NOT
  `Ezagent.Kind.Snapshot.save_now/3`): this module lives in `ezagent_core`,
  which has NO compile/runtime dependency on the domain-owned session Kind
  modules, and `save_now/3` would require resolving a Kind module. We strip
  transients (`Ezagent.Kind.Snapshot.strip_transients/1`) so the rewritten row
  is byte-identical to what the runtime persists. Same allowlisted-write
  pattern as `Ezagent.Kind.KindBaseBackfill`.

  Do NOT run this against a live/dev/prod node — write + test it, then run it
  only as the operator cutover step above.
  """

  require Logger

  alias Ezagent.Ecto.KindSnapshot

  @old_slice_key :chat
  @new_slice_key :session

  @doc """
  Pure transform: rename the top-level `:chat` slice key to `:session` in a
  decoded snapshot state map, preserving the value.

  Returns `{:renamed, new_state}` when the row carried `:chat` (and did NOT
  already carry `:session` — a `:chat`+`:session` row is genuinely corrupt and
  fails loud), `{:noop, state}` when the row is already `:session`-keyed (or
  carries neither — a non-session row), or `{:error, {:both_keys_present,
  keys}}` for the corrupt double-keyed case.
  """
  @spec rename_slice_key(map()) ::
          {:renamed, map()} | {:noop, map()} | {:error, {:both_keys_present, [atom()]}}
  def rename_slice_key(state) when is_map(state) do
    has_old? = Map.has_key?(state, @old_slice_key)
    has_new? = Map.has_key?(state, @new_slice_key)

    cond do
      has_old? and has_new? ->
        # Neither code era writes BOTH — a row with both is corrupt. Fail loud
        # rather than silently dropping one (per `feedback_let_it_crash`).
        {:error, {:both_keys_present, Map.keys(state)}}

      has_old? ->
        {value, without_old} = Map.pop(state, @old_slice_key)
        {:renamed, Map.put(without_old, @new_slice_key, value)}

      true ->
        # Already `:session`-keyed (fresh new-code row) or not a chat session —
        # nothing to do.
        {:noop, state}
    end
  end

  @doc """
  Run the slice-key rename over every persisted session snapshot that still
  carries a `:chat` slice.

  For each such row: decode → rename `:chat` → `:session` → persist back via a
  direct `Ezagent.Ecto.KindSnapshot.upsert/5` (transients stripped). A row
  carrying BOTH `:chat` and `:session` FAILS LOUD (raises) — never guesses
  which to keep.

  Options:
    * `:dry_run` (boolean, default `false`) — report without writing.

  Returns `{:ok, %{scanned: n, renamed: n, already: n, dry_run: n}}`.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    all_rows()
    |> Enum.reduce(%{scanned: 0, renamed: 0, already: 0, dry_run: 0}, fn row, acc ->
      acc = %{acc | scanned: acc.scanned + 1}

      case KindSnapshot.decode_state(row) do
        {:ok, state} -> rename_row(row, state, dry_run?, acc)
        :error -> raise_undecodable(row, :empty)
        {:error, reason} -> raise_undecodable(row, reason)
      end
    end)
    |> then(&{:ok, &1})
  end

  @doc """
  Go/no-go gate. Returns `{:ok, count}` where `count` is the number of session
  snapshot rows that STILL carry a top-level `:chat` slice. `count == 0` is the
  green light to start new-code nodes; `> 0` means the migration has not run.
  """
  @spec gate() :: {:ok, non_neg_integer()}
  def gate do
    count =
      all_rows()
      |> Enum.count(fn row ->
        case KindSnapshot.decode_state(row) do
          {:ok, state} -> Map.has_key?(state, @old_slice_key)
          # An undecodable row cannot be proven migrated — count it as
          # not-go so the gate fails loud rather than green-lighting.
          _ -> true
        end
      end)

    {:ok, count}
  end

  # --- internals -------------------------------------------------------------

  defp rename_row(row, state, dry_run?, acc) do
    case rename_slice_key(state) do
      {:renamed, new_state} ->
        if dry_run? do
          %{acc | dry_run: acc.dry_run + 1}
        else
          persist(row, new_state)
          %{acc | renamed: acc.renamed + 1}
        end

      {:noop, _state} ->
        %{acc | already: acc.already + 1}

      {:error, {:both_keys_present, keys}} ->
        raise ArgumentError,
              "Ezagent.Session.SliceMigration: session snapshot #{row.uri} carries " <>
                "BOTH :chat AND :session slices (#{inspect(keys)}). No code era writes " <>
                "both — this row is corrupt. Refusing to guess which to keep; inspect " <>
                "(`mix ezagent.snapshot.dump #{row.uri}`) and fix the data."
    end
  end

  # Write the renamed state back via the ECTO upsert directly — NOT via
  # `Snapshot.save_now/3` (same rationale as `KindBaseBackfill.persist_backfilled/2`:
  # this module lives in ezagent_core with no dependency on the domain session
  # Kind modules `save_now/3` would resolve). The row already carries the
  # correct `kind_type`, `version`, and `workspace_uri`; we mutate ONLY the
  # state binary. Strip transients so the persisted shape matches the runtime's.
  defp persist(row, new_state) do
    binary =
      new_state
      |> Ezagent.Kind.Snapshot.strip_transients()
      |> :erlang.term_to_binary()

    case KindSnapshot.upsert(row.uri, row.kind_type, binary, row.version, row.workspace_uri) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        raise "Ezagent.Session.SliceMigration: failed to persist renamed " <>
                ":session slice for #{row.uri}: #{inspect(reason)}"
    end
  end

  # Scan EVERY snapshot, not just `kind_type == "session"` (codex P2): the old
  # Chat behavior was registered for `:receive` on the User AND Agent Kinds too,
  # so a User/Agent row that ever received a message carries the same `:chat`
  # slice (its `last_received`/cursor-ring receive-state). The renamed runtime
  # reads `:session` on those Kinds as well, so an unmigrated `:chat` there is
  # equally stale. `rename_slice_key/1` noops any row without a `:chat` key, so
  # scanning all rows is safe — and the gate now counts a stale `:chat` on ANY
  # Kind, not falsely green-lighting on lingering User/Agent rows.
  defp all_rows, do: KindSnapshot.list_all()

  defp raise_undecodable(row, reason) do
    raise "Ezagent.Session.SliceMigration: session snapshot #{row.uri} is " <>
            "undecodable (#{inspect(reason)}) — refusing to rewrite over an " <>
            "unloadable row (would risk durable state). Fix/clear the row first."
  end
end
