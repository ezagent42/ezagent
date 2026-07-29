defmodule Ezagent.PluginCurlAgent.CurlSnapshotMigration do
  @moduledoc """
  Forward-only snapshot migration: rewrite every pre-fold `curl_agent`
  `kind_snapshots` row onto the unified `Ezagent.Entity.Agent` Kind + `curl`
  flavor (PR-6+7 curl-as-flavor).

  ## Why this exists (the ordered cutover precondition)

  PR-6+7 DELETED the standalone curl Kind (formerly `type_name :curl_agent`)
  and removed its `agent_module_resolver.ex` branch. Allen overrode the spec's
  reversible `kind_type` alias / rollback window — this is a forward-only
  rewrite, NO dual-state, NO standalone curl Kind to fall back to.

  Because there is no fallback Kind, this migration MUST run BEFORE a new-code
  node serves any old curl row (the same ordered-cutover discipline as the
  `Ezagent.Kind.KindBaseBackfill` / `Ezagent.Session.SliceMigration` snapshot
  migrations). After it runs, every former `curl_agent` row carries
  `kind_type "agent"` and cold-loads as `Entity.Agent` with the curl flavor.

  ## What it rewrites (per `kind_type == "curl_agent"` row), spec §6.1 step 2

    1. **`kind_type` → `"agent"`** — so cold-load resolves `Entity.Agent` (the
       unified Kind) instead of the deleted standalone curl Kind.
    2. **`:kind_base` slice** ← the curl per-instance behavior SET
       (`Ezagent.Entity.Agent.curl_behaviors/0`), in the two-container shape
       `Ezagent.ActionSet.KindBase.create/1` persists — so
       `Ezagent.Kind.BehaviorSet.effective_set/2` selects the curl subset on
       cold-load, identical to a freshly-spawned curl agent.
    3. **`flavor: "curl"`** set on the durable `:curl_agent` slice (O-2: flavor
       is a STORED slice field, read at load). A pre-fold row's `:curl_agent`
       slice has NO `:flavor` key (the standalone Kind never wrote it).
    4. **`:curl_agent → :agent` cap-axis** — every persisted `%Capability{kind:
       :curl_agent}` anywhere in the row's state is rewritten to `:agent` (the
       unified Kind's axis). `reset_conversation` / `configure` cap subjects
       move with them.

  PRESERVED unchanged: the `:curl_agent` slice content
  (provider/api_url/model/system_prompt/max_history/conversation/last_error/
  last_tokens), the `:api_keys` slice, and the `:creator_uri` data-owner
  provenance inside `:api_keys` (key-rotation authz depends on it).

  ## Migration boundary (#52 lesson)

  TEST / sandbox DB ONLY (per the spec + memory
  `feedback_destructive_migration_anti_pattern`). The operator front door
  (`mix ezagent.curl.migrate`) starts ONLY the Repo via
  `Ecto.Migrator.with_repo/2` — it does NOT `app.start` the domain runtime
  before the rewrite (a half-booted node would try to cold-load the very rows
  this migration is repairing, against the deleted Kind). The rewrite is a pure
  ETS-free read → transform → `Ezagent.Ecto.KindSnapshot.upsert/5` over the
  binary `state_binary` column (same direct-upsert technique as
  `KindBaseBackfill`, which lives in core and cannot resolve a domain Kind
  module either — we don't need one: the row already carries everything we
  rewrite).
  """

  require Logger

  alias Ezagent.ActionSet.KindBase
  alias Ezagent.Ecto.KindSnapshot

  # The pre-fold standalone-curl-Kind `kind_type` (its `type_name` was
  # `:curl_agent`). Selects the rows to migrate.
  @legacy_kind_type "curl_agent"

  # The unified Agent Kind's `kind_type` (`Entity.Agent.type_name == :agent`).
  # Written into the migrated row so cold-load resolves `Entity.Agent`.
  @unified_kind_type "agent"

  # The durable slice the reparented `Ezagent.ActionSet.CurlAgent` owns.
  @curl_slice_key :curl_agent

  # Slices the PRE-FOLD standalone curl Kind already owned. They MUST be present
  # on a real legacy row (they hold the durable conversation / API keys /
  # creator provenance); a missing one means a corrupt row that must fail loud,
  # not be fabricated (codex P2). Every OTHER non-universal curl behavior slice
  # is genuinely ADDED by the unified Agent set and is synthesized on migrate.
  @legacy_owned_slices [:curl_agent, :api_keys]

  @type counts :: %{
          scanned: non_neg_integer(),
          migrated: non_neg_integer(),
          already: non_neg_integer()
        }

  @doc """
  The unified curl behavior SET stored into `:kind_base` (module atoms). Read
  lazily so a test can assert against the live `Entity.Agent.curl_behaviors/0`
  without this module pinning a stale copy.
  """
  @spec curl_behavior_set() :: [module()]
  def curl_behavior_set, do: Ezagent.Entity.Agent.curl_behaviors()

  @doc """
  Is this a row that still needs migrating? `true` for a row whose `kind_type`
  is the legacy `"curl_agent"`. A row already at `"agent"` (migrated, or a
  native unified agent) is skipped.
  """
  @spec needs_migration?(KindSnapshot.t()) :: boolean()
  def needs_migration?(%KindSnapshot{kind_type: @legacy_kind_type}), do: true
  def needs_migration?(%KindSnapshot{}), do: false

  @doc """
  Pure transform of a decoded `curl_agent` snapshot STATE → the migrated state.

  Performs steps 2-4 (the in-state rewrites): sets the curl `:kind_base`,
  sets `flavor: "curl"` on the `:curl_agent` slice, and rewrites every
  `:curl_agent` cap-axis subject to `:agent`. Step 1 (`kind_type`) is applied
  at persist time (it lives in the row's column, not the state map).

  Returns the new state map. Idempotent: re-running over an already-migrated
  state is a no-op (the `:flavor` is already set, the caps already `:agent`,
  the `:kind_base` already the curl set).
  """
  @spec migrate_state(URI.t(), map()) :: map()
  def migrate_state(%URI{} = uri, state) when is_map(state) do
    state
    |> put_kind_base()
    |> materialize_added_behavior_slices(uri)
    |> put_curl_flavor()
    |> rewrite_cap_axis()
  end

  # Step 2 — materialize the curl behavior set into `:kind_base` in the exact
  # two-container shape `KindBase.create/1` persists, so a cold-load's
  # `effective_set/2` re-derives the same curl subset as a fresh spawn.
  defp put_kind_base(state) do
    kind_base_key = KindBase.state_slice()
    slice = %{state: %{behaviors: curl_behavior_set()}, transients: %{}}
    Map.put(state, kind_base_key, slice)
  end

  # Step 2b (cold-load correctness — the #52 / cold-restart bug class) —
  # materialize the slices for the behaviors the curl set ADDS that the pre-fold
  # standalone curl Kind never had (Session / Identity / Sandbox /
  # CredentialGrant / ConfigEvolve; the old Kind carried ONLY `:curl_agent` +
  # `:api_keys`). Without this, a cold-load runs each added behavior's
  # `init_slice/1`, which is `ever_created?`-gated to EMPTY (it expects the
  # snapshot to supply the real slice) — so e.g. `Behavior.Sandbox.activate/2`
  # would `KeyError` on `state.template_class` against an empty `%{}`. We seed
  # each MISSING slice with its `create/1` default (the SAME fresh-spawn value a
  # newly-created curl agent gets), in the two-container shape; `transients`
  # start empty and `activate/2` rebuilds them on the cold-load. Universal
  # behaviors (`KindBase` is set in step 2 above; `Manage` owns no slice) are
  # excluded, exactly as `Kind.Snapshot.init_fresh_for_set/2` excludes them.
  defp materialize_added_behavior_slices(state, %URI{} = uri) do
    universal = MapSet.new(Ezagent.UniversalBehaviors.all())

    Ezagent.Entity.Agent.curl_behaviors()
    |> Enum.reject(&MapSet.member?(universal, &1))
    |> Enum.reduce(state, fn behavior, acc ->
      slice_key = behavior.state_slice()

      cond do
        Map.has_key?(acc, slice_key) ->
          # Slice already present (e.g. `:curl_agent`, `:api_keys`) — preserve it
          # unchanged (carry-forward, spec §6.1 step 3).
          acc

        slice_key in @legacy_owned_slices ->
          # A slice the PRE-FOLD standalone curl Kind already owned
          # (`:curl_agent` conversation, `:api_keys` keys + creator provenance)
          # is MISSING — the row is corrupt/truncated. FAIL LOUD (codex P2):
          # synthesizing an empty `create/1` default here would turn an
          # unloadable row into a migrated agent with LOST conversation / keys /
          # creator, violating the fail-loud contract. Only the truly-ADDED
          # Agent behaviors below may be synthesized.
          # (`uri_str` bound on its own line so this error message — which
          # mentions `slice_key` → trips the uri_string_key `_key` heuristic —
          # carries no `URI.to_string` token; it's a human error string, not a
          # routing/cap key.)
          uri_str = URI.to_string(uri)

          raise "Ezagent.PluginCurlAgent.CurlSnapshotMigration: curl_agent row " <>
                  "#{uri_str} is missing the legacy-owned #{inspect(slice_key)} " <>
                  "slice — refusing to fabricate it (would lose durable " <>
                  "conversation/credential/provenance state). Fix/clear the row first."

        true ->
          # A behavior the unified curl SET ADDS that the narrow standalone Kind
          # never had (Session / Identity / Sandbox / CredentialGrant /
          # ConfigEvolve) — synthesize its fresh-spawn default so a cold-load
          # doesn't `KeyError` (the #52 cold-restart bug class). Pass the row URI
          # exactly as a fresh `Entity.Agent` spawn does: most behaviors ignore
          # it, but `Behavior.Identity.create/1` reads `:uri` to embed the
          # agent's self-scoped `Sandbox.update_config` + `ConfigEvolve.reconcile_cascade`
          # caps (else config-evolve self-dispatch is unauthorized after
          # migration — codex P1, r4).
          {:ok, created} = behavior.create(%{uri: uri})
          Map.put(acc, slice_key, %{state: created, transients: %{}})
      end
    end)
  end

  # Step 3 — set the durable `flavor: "curl"` field on the `:curl_agent` slice.
  # A pre-fold row's slice never carried it (the standalone Kind didn't write a
  # flavor); the reparented `Behavior.CurlAgent.create/1` writes it for fresh
  # agents, so a migrated row matches a fresh one. Tolerates the two-container
  # `%{state: ..., transients: ...}` shape AND a flat legacy slice.
  defp put_curl_flavor(state) do
    case Map.get(state, @curl_slice_key) do
      %{state: inner} = two_container when is_map(inner) ->
        Map.put(state, @curl_slice_key, %{two_container | state: Map.put(inner, :flavor, "curl")})

      flat when is_map(flat) ->
        Map.put(state, @curl_slice_key, Map.put(flat, :flavor, "curl"))

      _ ->
        # No `:curl_agent` slice at all — a corrupt/foreign row mislabeled
        # `curl_agent`. Leave it; the persist step still rewrites kind_type, and
        # a slice-less curl row would fail loud at cold-load (never silently
        # mutated here).
        state
    end
  end

  # Step 4 — rewrite every `%Capability{kind: :curl_agent}` reachable in the
  # state to `:agent`. Walks maps, lists, MapSets, and tuples so a cap held in
  # ANY slice container (e.g. an `:identity` slice's `caps` MapSet) is caught.
  defp rewrite_cap_axis(term), do: deep_rewrite_cap(term)

  defp deep_rewrite_cap(%Ezagent.Capability{kind: :curl_agent} = cap),
    do: %{cap | kind: :agent}

  defp deep_rewrite_cap(%Ezagent.Capability{} = cap), do: cap

  defp deep_rewrite_cap(%MapSet{} = set) do
    set |> MapSet.to_list() |> Enum.map(&deep_rewrite_cap/1) |> MapSet.new()
  end

  defp deep_rewrite_cap(%_{} = struct) do
    # A non-Capability struct (e.g. %URI{}, %Message{}) — recurse into its
    # fields so a cap nested inside is still rewritten, then rebuild the struct.
    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, deep_rewrite_cap(v)} end)
    |> Enum.into(%{})
    |> then(&struct(struct.__struct__, &1))
  end

  defp deep_rewrite_cap(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, deep_rewrite_cap(v)} end)
  end

  defp deep_rewrite_cap(list) when is_list(list), do: Enum.map(list, &deep_rewrite_cap/1)

  defp deep_rewrite_cap(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&deep_rewrite_cap/1) |> List.to_tuple()
  end

  defp deep_rewrite_cap(other), do: other

  @doc """
  Run the migration over every `curl_agent` snapshot row.

  For each: decode → `migrate_state/1` → persist back via
  `KindSnapshot.upsert/5` with the rewritten `kind_type "agent"`. An
  undecodable row FAILS LOUD (raises) — never guesses, never persists over an
  unloadable row.

  Options:
    * `:dry_run` (boolean, default `false`) — count + classify without writing.

  Returns `{:ok, %{scanned, migrated, already, dry_run}}`.

  Only `curl_agent` ROWS are touched: with no back-compat (Allen 2026-06-13) the
  cutover is total — no code mints a cross-entity `%Capability{kind: :curl_agent}`
  grant (the only `:curl_agent` caps were SELF-caps in a curl agent's own
  `:identity` slice, rewritten in-row by `migrate_state/2`), so there is no
  stranded cross-store grant to chase.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    counts =
      legacy_rows()
      |> Enum.reduce(%{scanned: 0, migrated: 0, already: 0, dry_run: 0}, fn row, acc ->
        acc = %{acc | scanned: acc.scanned + 1}

        case KindSnapshot.decode_state(row) do
          {:ok, state} -> migrate_row(row, state, dry_run?, acc)
          :error -> raise_undecodable(row, :empty)
          {:error, reason} -> raise_undecodable(row, reason)
        end
      end)

    {:ok, counts}
  end

  @doc """
  Go/no-go gate. `{:ok, count}` where `count` is the number of `curl_agent`
  rows STILL present. `0` is the green light: every curl row has been migrated
  onto the unified Kind (a forward-only cutover precondition — with the legacy
  Kind deleted, a remaining `curl_agent` row would fail to cold-load).
  """
  @spec gate() :: {:ok, non_neg_integer()}
  def gate, do: {:ok, length(legacy_rows())}

  # --- internals -------------------------------------------------------------

  defp migrate_row(row, state, dry_run?, acc) do
    if dry_run? do
      %{acc | dry_run: acc.dry_run + 1}
    else
      uri = Ezagent.URI.new!(row.uri)
      new_state = migrate_state(uri, state)
      persist_migrated(row, new_state)
      ensure_authority_history(uri)
      %{acc | migrated: acc.migrated + 1}
    end
  end

  # A pre-#1457 curl row created before authority history existed (and never
  # reopened since) has NO `kind_cap_authorities` rows. Post-#1621 the cold
  # load REFUSES such a principal (`:no_authority_for_existing` — the
  # anti-resurrection guard), so a migrated-but-history-less row would be
  # permanently unbootable. This operator-run, pre-serving migration is the
  # legitimate adoption point: open `:created` authority for the row's real,
  # previously-created agent so the unified row cold-loads. Idempotent — rows
  # that already have history are left untouched.
  defp ensure_authority_history(%URI{} = uri) do
    instance = Ezagent.URI.instance(uri)

    unless Ezagent.Cap.Authority.has_authority_history?(instance) do
      case Ezagent.Cap.Authority.open(instance, :agent, :created) do
        {:ok, _authority} ->
          :ok

        {:error, reason} ->
          raise "Ezagent.PluginCurlAgent.CurlSnapshotMigration: failed to adopt " <>
                  "authority history for #{URI.to_string(uri)}: #{inspect(reason)} — " <>
                  "the migrated row would be unbootable (anti-resurrection guard)"
      end
    end
  end

  # Write the migrated state back with the rewritten `kind_type "agent"`. Strip
  # transients (`Ezagent.Kind.Snapshot.strip_transients/1`) so the persisted
  # binary matches exactly what the runtime would write for a fresh curl agent.
  # `version` + `workspace_uri` carry over from the existing row unchanged.
  defp persist_migrated(row, new_state) do
    binary =
      new_state
      |> Ezagent.Kind.Snapshot.strip_transients()
      |> :erlang.term_to_binary()

    case KindSnapshot.upsert(row.uri, @unified_kind_type, binary, row.version, row.workspace_uri) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        raise "Ezagent.PluginCurlAgent.CurlSnapshotMigration: failed to persist " <>
                "migrated curl_agent row #{row.uri}: #{inspect(reason)}"
    end
  end

  defp legacy_rows do
    KindSnapshot.list_all() |> Enum.filter(&needs_migration?/1)
  end

  defp raise_undecodable(row, reason) do
    raise "Ezagent.PluginCurlAgent.CurlSnapshotMigration: curl_agent snapshot " <>
            "#{row.uri} is undecodable (#{inspect(reason)}) — refusing to migrate " <>
            "over an unloadable row (would risk durable conversation/credential " <>
            "state). Fix/clear the row first."
  end
end
