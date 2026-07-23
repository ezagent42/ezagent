defmodule Ezagent.Kind.KindBaseBackfill do
  @moduledoc """
  P5-0 (socialware substrate collapse) — backfill every persisted session
  snapshot's `:kind_base` slice with its concrete as-built behavior set, and
  the go/no-go gate that proves ZERO nil/missing `:kind_base` session rows
  remain.

  ## Why this exists (the load-bearing precondition for P5-1)

  `Ezagent.Kind.BehaviorSet.effective_set/2` expands a NIL / missing
  `:kind_base` capture to the host Kind's FULL declared list (the legacy
  sentinel rule). Today every session-spawn path omits `:behaviors`, so every
  session snapshot persists `%{behaviors: nil}` — which is FINE today because
  each session Kind's declared list IS its own set (chat ≠ socialware, two
  distinct Kinds).

  P5-1 will collapse both into ONE Kind whose declared list is the UNION
  `{Chat, Publisher.SessionImpl, ExternalMirror, Turn, Surface}`. At that
  point a nil-`:kind_base` chat row would cold-load with the entire socialware
  superset, silently breaking P1's "chat denies `surface.*`/`turn.*`"
  invariant. This module sets every existing session row's `:kind_base` to the
  concrete set BEFORE the union lands.

  ## Classification — socialware is POSITIVE, chat is the DEFAULT

  Both former Session Kinds (the chat `Ezagent.Entity.Session` and the
  standalone socialware-session Kind, since collapsed into the unified
  `Entity.Session`) persist `kind_type "session"`, so `kind_type` cannot
  distinguish a legacy row's intended subset. We
  classify by the slice keys actually present in the durable state — but the
  ONLY positively-identifying mark is a socialware slice. `:external_mirror`
  is OPTIONAL for chat (a chat Session that never created a mirror binding
  persists with ONLY `:chat`), so chat must be the DEFAULT, not gated on
  `:external_mirror`:

    * a `:surface` OR `:turns` slice present (and NO `:external_mirror`)
      ⇒ **socialware** ⇒ `{Chat, Publisher.SessionImpl, Turn, Surface}`
    * a recognizable session (has `:chat` and/or `:publisher`) with NO
      socialware slice ⇒ **chat** ⇒ `{Chat, Publisher.SessionImpl,
      ExternalMirror}` — REGARDLESS of whether `:external_mirror` is present
      (it is optional for an older/minimal chat row)
    * `:surface`/`:turns` AND `:external_mirror` TOGETHER ⇒ **ambiguous**
      fail-loud — neither Kind declares both, so the row is genuinely corrupt
    * NO `:chat`, NO `:publisher`, and no session slice at all (not a session)
      ⇒ **unclassifiable** fail-loud — never guess

  ## Migration boundary

  TEST / sandbox DB only (per the P5 plan). The module reads + rewrites
  `kind_snapshots` rows via a direct `Ezagent.Ecto.KindSnapshot.upsert/5`
  (NOT `Ezagent.Kind.Snapshot.save_now/3`): this module lives in
  `ezagent_core`, which has NO compile/runtime dependency on the domain-owned
  session Kind modules, and `save_now/3` would require resolving a Kind
  module. We strip transients (`Ezagent.Kind.Snapshot.strip_transients/1`) so
  the rewritten `:kind_base` two-container slice is byte-identical to what
  `KindBase.create/1` would have persisted with an explicit `:behaviors` arg.
  """

  require Logger

  alias Ezagent.ActionSet.KindBase
  alias Ezagent.Ecto.KindSnapshot

  # Slice keys that POSITIVELY mark a snapshot as socialware-shaped. Sourced
  # from the socialware-only behaviors' `state_slice/0`: Turn → :turns,
  # Surface → :surface. (Chat + Publisher are shared by BOTH session Kinds and
  # so are NOT discriminating.)
  @socialware_slice_keys [:turns, :surface]
  # Slice key declared ONLY by the chat Session (ExternalMirror →
  # :external_mirror). Present in a chat row, but OPTIONAL: a chat Session that
  # never created a mirror binding persists WITHOUT it. Used only to detect the
  # ambiguous (socialware + external_mirror) corruption, NEVER to gate chat.
  @external_mirror_slice_key :external_mirror
  # Slice keys shared by BOTH session Kinds. Their presence (with no socialware
  # slice) is what makes a row a recognizable CHAT session — the default.
  @session_marker_slice_keys [:session, :publisher]

  # The STRING forms of the session slice keys. A snapshot decoded from the
  # LEGACY JSON `state` column (`KindSnapshot.decode_state/1` fallback) has
  # STRING top-level keys, NOT atoms — so the atom `Map.has_key?` checks below
  # would all miss and mis-report a perfectly recognizable session as
  # `:unclassifiable`. We detect that shape FIRST and fail loud with a PRECISE,
  # actionable message instead. We do NOT atom-normalize + classify: only the
  # TOP-LEVEL keys could be safely atomized (a finite framework set), but the
  # NESTED slice content stays string-keyed JSON, so the rewritten binary row
  # would still fail to load at runtime — a legacy row must be re-saved as a
  # binary snapshot (which the runtime does on its next commit) BEFORE backfill.
  @legacy_json_marker_keys ~w(session publisher turns surface external_mirror)

  # The stable type atom every session row carries (both former Session Kinds,
  # now the single unified `Entity.Session`).
  @session_kind_type "session"

  # As-built concrete behavior sets (the value stored verbatim in `:kind_base`,
  # WITHOUT the always-on base behaviors KindBase/Manage which BehaviorSet
  # appends). These are module ATOM references only — no function is called on
  # them here, so referencing them creates NO compile dependency on the domain
  # apps (same pattern as BehaviorSet.@slice_owners, which lives in core).
  @instance_message_set [
    Ezagent.ActionSet.Session,
    Ezagent.ActionSet.Publisher.SessionImpl,
    Ezagent.ActionSet.ExternalMirror
  ]

  # Order matches the former socialware-session Kind's behavior set exactly —
  # now `Entity.Session.socialware_behaviors/0` (Session, Turn, Surface,
  # SupervisorApproval, Publisher.SessionImpl) — so a backfilled :kind_base is
  # byte-identical to a live socialware spawn — the P5-2 cold-restart round-trip
  # invariant compares the raw captured list, not just the (reorder-normalized)
  # effective set. (codex LOW)
  @socialware_set [
    Ezagent.ActionSet.Session,
    Ezagent.ActionSet.Turn,
    Ezagent.ActionSet.Surface,
    Ezagent.ActionSet.SupervisorApproval,
    Ezagent.ActionSet.Publisher.SessionImpl
  ]

  @type classification :: :instance_message | :socialware
  @type classify_error ::
          {:ambiguous, [atom()]}
          | {:unclassifiable, [atom()]}
          | {:legacy_json_unsupported, [String.t()]}

  @doc "The as-built behavior set for a classification (module atoms, no base behaviors)."
  @spec target_behaviors(classification()) :: [module()]
  def target_behaviors(:instance_message), do: @instance_message_set
  def target_behaviors(:socialware), do: @socialware_set

  @doc """
  Classify a decoded session snapshot state by its durable slice shape.

  Socialware is identified POSITIVELY (it owns the `:surface`/`:turns` slices);
  chat is the DEFAULT for any recognizable session that is not socialware,
  because `:external_mirror` is OPTIONAL for chat.

  Returns `{:ok, :socialware}` / `{:ok, :instance_message}`, or fails loud with
  `{:error, {:ambiguous, keys}}` (socialware slice AND `:external_mirror` —
  neither Kind declares both) / `{:error, {:unclassifiable, keys}}` (not a
  session at all) for a row that cannot be unambiguously placed.
  """
  @spec classify_session_state(map()) :: {:ok, classification()} | {:error, classify_error()}
  def classify_session_state(state) when is_map(state) do
    keys = Map.keys(state)
    has_socialware? = Enum.any?(@socialware_slice_keys, &Map.has_key?(state, &1))
    has_external_mirror? = Map.has_key?(state, @external_mirror_slice_key)
    is_session? = Enum.any?(@session_marker_slice_keys, &Map.has_key?(state, &1))

    cond do
      # A LEGACY JSON-column row decodes to STRING top-level keys. Detect it
      # FIRST so a recognizable-but-string-keyed session is NOT mis-reported as
      # `:unclassifiable`. Fail loud with a precise, actionable error (see
      # `@legacy_json_marker_keys`): the row must be re-saved as a binary
      # snapshot before `:kind_base` backfill.
      not is_session? and not has_socialware? and not has_external_mirror? and
          legacy_json_session?(state) ->
        {:error, {:legacy_json_unsupported, keys}}

      # Socialware slice AND a chat-only mirror slice: neither Kind declares
      # both. Genuinely corrupt — fail loud.
      has_socialware? and has_external_mirror? ->
        {:error, {:ambiguous, keys}}

      # Positively socialware (and not ambiguous).
      has_socialware? ->
        {:ok, :socialware}

      # Any recognizable session that is NOT socialware is chat — whether or not
      # it carries the optional :external_mirror slice.
      is_session? or has_external_mirror? ->
        {:ok, :instance_message}

      # Not a session at all — never guess.
      true ->
        {:error, {:unclassifiable, keys}}
    end
  end

  # A decoded state is a LEGACY JSON session row when it carries a STRING
  # session-marker key (the JSON column never produces atom keys). Pure string
  # check — never consults atom presence.
  defp legacy_json_session?(state) do
    Enum.any?(@legacy_json_marker_keys, &Map.has_key?(state, &1))
  end

  @doc """
  Is the `:kind_base` slice nil / missing for this state?

  `true` when the slice key is absent, OR present but captures the legacy
  sentinel `nil` (`KindBase.behaviors_in_slice/1` returns `nil`). `false` when
  it captures a present list (already backfilled / spawned with `:behaviors`).
  """
  @spec kind_base_missing?(map()) :: boolean()
  def kind_base_missing?(state) when is_map(state) do
    kind_base_key = KindBase.state_slice()

    case Map.fetch(state, kind_base_key) do
      :error -> true
      {:ok, slice} -> is_nil(KindBase.behaviors_in_slice(slice))
    end
  end

  @doc """
  Pure transform: backfill a decoded session snapshot state's `:kind_base`
  slice with the classified as-built set.

  Returns `{:ok, new_state}` with `:kind_base` set to the two-container shape
  `KindBase` persists (`%{state: %{behaviors: set}, transients: %{}}`), or
  `{:error, reason}` from classification (fail-loud, state unchanged).
  """
  @spec backfill_state(map()) :: {:ok, map()} | {:error, classify_error()}
  def backfill_state(state) when is_map(state) do
    with {:ok, classification} <- classify_session_state(state) do
      set = target_behaviors(classification)
      kind_base_key = KindBase.state_slice()
      new_slice = %{state: %{behaviors: set}, transients: %{}}
      {:ok, Map.put(state, kind_base_key, new_slice)}
    end
  end

  @doc """
  Run the backfill over every persisted session snapshot whose `:kind_base` is
  nil / missing.

  For each such row: decode → classify by slice shape → rewrite `:kind_base` →
  persist back via a direct `Ezagent.Ecto.KindSnapshot.upsert/5` (NOT
  `Snapshot.save_now/3`, which would pull a core→domain-Kind dependency). A row
  that cannot be classified FAILS LOUD (raises) — the whole task aborts, never
  guesses.

  Options:
    * `:dry_run` (boolean, default `false`) — classify + report without writing.

  Returns `{:ok, %{scanned: n, backfilled: n, already: n, dry_run: n,
  legacy_cleared: n}}`. A legacy JSON-column (string-keyed) row has its unusable
  state CLEARED with a warning while retaining its Lifecycle `ever_created`
  marker (it can neither be auto-migrated nor runtime-reloaded under the P5-0b
  guard; clearing the state lets `gate/0` reach zero without making a later
  spawn look like a genuine first creation). Raises on the FIRST genuinely-
  corrupt unclassifiable / ambiguous (atom-keyed) row.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    session_rows()
    |> Enum.reduce(
      %{scanned: 0, backfilled: 0, already: 0, dry_run: 0, legacy_cleared: 0},
      fn row, acc ->
        acc = %{acc | scanned: acc.scanned + 1}

        case KindSnapshot.decode_state(row) do
          {:ok, state} -> backfill_row(row, state, dry_run?, acc)
          :error -> raise_undecodable(row, :empty)
          {:error, reason} -> raise_undecodable(row, reason)
        end
      end
    )
    |> then(&{:ok, &1})
  end

  @doc """
  Go/no-go gate. Returns `{:ok, count}` where `count` is the number of session
  snapshot rows whose `:kind_base` is STILL nil / missing. `count == 0` is the
  green light for P5-1 to proceed; `> 0` means the backfill has not (fully) run.
  """
  @spec gate() :: {:ok, non_neg_integer()}
  def gate do
    count =
      session_rows()
      |> Enum.count(fn row ->
        case KindSnapshot.decode_state(row) do
          {:ok, state} -> kind_base_missing?(state) and not marker_only_clear?(row, state)
          # An undecodable row cannot be proven backfilled — count it as
          # not-go so the gate fails loud rather than green-lighting.
          _ -> true
        end
      end)

    {:ok, count}
  end

  # --- internals -------------------------------------------------------------

  defp backfill_row(row, state, dry_run?, acc) do
    if kind_base_missing?(state) and not marker_only_clear?(row, state) do
      case backfill_state(state) do
        {:ok, new_state} ->
          if dry_run? do
            %{acc | dry_run: acc.dry_run + 1}
          else
            persist_backfilled(row, new_state)
            %{acc | backfilled: acc.backfilled + 1}
          end

        {:error, {:legacy_json_unsupported, _keys} = reason} ->
          # A legacy JSON-column row (string-keyed) CANNOT be auto-migrated:
          # atom-normalizing only its top-level keys would leave nested slice
          # content (e.g. JSON-flattened `%URI{}` member keys) string-keyed and
          # unloadable, and it can no longer be re-saved through the runtime
          # either — the P5-0b guard raises `MissingKindBaseError` on its
          # nil/missing `:kind_base` before it could re-commit a binary snapshot.
          # Such a row is therefore ALREADY dead weight (it can neither backfill
          # nor load). Per Allen (2026-06-12) an un-migratable legacy row may be
          # CLEARED outright: remove its unusable state so the gate can reach
          # zero (no manual step), but retain `ever_created` so a later spawn is
          # activation, never a genuine first creation. No current code writes
          # the legacy `state` column (`KindSnapshot.upsert/6` writes only
          # `state_binary`), so this is defensive — it should never fire on any
          # post-Phase-1 DB.
          Logger.warning(
            "Ezagent.Kind.KindBaseBackfill: CLEARING un-migratable legacy " <>
              "JSON-column session snapshot #{row.uri} (#{inspect(reason)}) — a " <>
              "lossy JSON row cannot be backfilled or runtime-reloaded; clearing " <>
              "its state while preserving ever_created so the gate can reach zero."
          )

          :ok = KindSnapshot.clear_state_preserving_marker(row.uri)
          %{acc | legacy_cleared: acc.legacy_cleared + 1}

        {:error, reason} ->
          raise ArgumentError,
                "Ezagent.Kind.KindBaseBackfill: session snapshot #{row.uri} is " <>
                  "unclassifiable/ambiguous (#{inspect(reason)}). Per P5-0 this MUST " <>
                  "fail loud — no guessing. Inspect the row " <>
                  "(`mix ezagent.snapshot.dump #{row.uri}`) and fix the data."
      end
    else
      %{acc | already: acc.already + 1}
    end
  end

  # Write the backfilled state back via the ECTO upsert directly — NOT via
  # `Snapshot.save_now/3`. This module lives in `ezagent_core`, which has no
  # compile/runtime dependency on the domain-owned session Kind module
  # (`Ezagent.Entity.Session`); calling
  # `kind_module.type_name/0` would crash when that module isn't loaded.
  # We don't NEED a module: the row already carries the correct `kind_type`
  # ("session"), `version`, and `workspace_uri`, and we mutate ONLY the state
  # binary. We strip transients (`Ezagent.Kind.Snapshot.strip_transients/1`) so
  # the persisted shape matches exactly what the runtime writes.
  defp persist_backfilled(row, new_state) do
    binary =
      new_state
      |> Ezagent.Kind.Snapshot.strip_transients()
      |> :erlang.term_to_binary()

    case KindSnapshot.upsert(row.uri, row.kind_type, binary, row.version, row.workspace_uri) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        raise "Ezagent.Kind.KindBaseBackfill: failed to persist backfilled " <>
                ":kind_base for #{row.uri}: #{inspect(reason)}"
    end
  end

  defp session_rows do
    KindSnapshot.list_all()
    |> Enum.filter(&(&1.kind_type == @session_kind_type))
  end

  # G-3/v4-H2b: a non-delete snapshot clear intentionally leaves an empty
  # marker-bearing row. Snapshot load reinitializes the declared slices while
  # Lifecycle sees `ever_created` and runs activation (never create), so this is
  # a terminal safe state for the historical backfill gate, not legacy debt.
  defp marker_only_clear?(%KindSnapshot{ever_created: true}, state), do: state == %{}
  defp marker_only_clear?(_row, _state), do: false

  defp raise_undecodable(row, reason) do
    raise "Ezagent.Kind.KindBaseBackfill: session snapshot #{row.uri} is " <>
            "undecodable (#{inspect(reason)}) — refusing to backfill over an " <>
            "unloadable row (would risk durable state). Fix/clear the row first."
  end
end
