defmodule Ezagent.Kind.BehaviorSet.UnclosedSetError do
  @moduledoc """
  Raised at `Snapshot.init_fresh_first_spawn/2` (first spawn) — and on the
  persisted effective set in the reload branch of `load_with_fallback/3` — when
  a requested/persisted instance behavior set is NOT closed under its required
  sibling reads (P1.1). Carries the `:missing` list of
  `{reader_module, missing_slice_key}` tuples. Because it is raised at the init
  chokepoint BEFORE any `init_slice`/`create` runs, the spawn aborts and NO
  partial slice is persisted.
  """
  defexception [:message, missing: []]
end

defmodule Ezagent.Kind.BehaviorSet.MissingKindBaseError do
  @moduledoc """
  P5-0b (socialware substrate collapse) — raised by
  `Ezagent.Kind.BehaviorSet.effective_set/2` when a Kind that declares
  `requires_explicit_behavior_set?/0 == true` (the session Kind(s)) has a
  nil / missing `:kind_base` capture.

  This is the SCOPED runtime fail-loud guard: it fires ONLY for the session
  Kind(s), never for legacy static non-session Kinds (whose absent-`:behaviors`
  → declared expansion is the intentional compat path). Once a session's
  declared list is the union (P5-1), a nil `:kind_base` would silently
  cold-load the entire superset and break P1's per-instance denial invariant —
  so for sessions a missing explicit set is a hard error, surfaced here.
  """
  defexception [:message, :kind_module]
end

defmodule Ezagent.Kind.BehaviorSet do
  @moduledoc """
  Per-instance behavior-set resolution + required/optional sibling
  closure for the unified socialware substrate (SPEC §3.1).

  Two entry points compute the instance set at different lifecycle moments:

  * `init_set/2` is called by `Snapshot.init_fresh_first_spawn/2` at FIRST
    spawn (the `:not_found` branch of `load_with_fallback/3`, fetched-first),
    BEFORE any slice (and thus any `:kind_base` slice) exists. It derives
    the set from the SPAWN ARGS, PLUS the always-on base behaviors
    (`base_behaviors/0`), using the SAME legacy-sentinel rule as
    `KindBase.create/1`: when `:behaviors` is ABSENT → the full declared
    list (legacy static Kind); when PRESENT (even the empty list `[]`) →
    `(list ∩ declared)`. So `%{behaviors: []}` on a superset Kind admits
    ONLY base behaviors, never the declared superset. `init_fresh_first_spawn`
    enumerates ONLY this set, so an out-of-set behavior's `create`/
    `init_slice` NEVER runs and its slice is NEVER created or persisted on
    first spawn (SPEC §3.1 — no "prune on next load" reliance for the
    security property).
  * `effective_set/2` is the single function every POST-LOAD runtime
    behavior enumeration calls instead of `Ezagent.Kind.behaviors_of/1`. It
    reads the captured value back from the persisted `:kind_base` slice via
    `KindBase.behaviors_in_slice/1`: the legacy sentinel `nil` (an absent-
    args instance, i.e. the two legacy static Kinds) → the FULL declared
    list (so existing Kinds are byte-for-byte unchanged); a PRESENT captured
    list (even `[]`) → the host Kind's declared behaviors INTERSECTED with
    that list, in declaration order.

  Both entry points include `base_behaviors/0` AND apply the identical
  absent-vs-present-empty distinction, so the two are symmetric: whatever
  `init_set` materializes at spawn is exactly what `effective_set` re-derives
  after reload. **An explicit `%{behaviors: []}` is NOT "absent" — it is a
  present empty list, so it can never be confused with omitted args and
  expand to the declared superset (codex CRITICAL).**
  """

  alias Ezagent.ActionSet.KindBase

  # SPEC §3.1 "universal-behavior fallback policy" — behaviors that are
  # ALWAYS in the instance set regardless of the spawn-args subset:
  #
  #   * `KindBase` — owns the `:kind_base` slice that PERSISTS the set; the
  #     instance cannot record its own set without it.
  #   * every `Ezagent.UniversalBehaviors.all/0` entry (today: `Manage`) —
  #     these resolve for EVERY Kind by construction (`BehaviorRegistry`
  #     falls back to them on a per-Kind miss) and are intentionally NOT in
  #     any Kind's `behaviors/0`. They must stay reachable on every instance
  #     so `manage.delete`/`manage.reconfigure` are never denied as
  #     out-of-set (E9 finding). They are exempt from the membership gate
  #     (Task 10) AND always part of the init/effective set here.
  @doc "Behaviors always present on every instance (KindBase + UniversalBehaviors.all/0)."
  @spec base_behaviors() :: [module()]
  def base_behaviors do
    Enum.uniq([KindBase | Ezagent.UniversalBehaviors.all()])
  end

  # P5-0b accessor — optional callback (default `false`); `Code.ensure_loaded?/1`
  # first for cold-VM load determinism. Scopes the `effective_set/2` nil-guard.
  # Extracted from `Ezagent.Kind` (oversized-module arch gate, 2026-06-23) —
  # `Ezagent.Kind.requires_explicit_behavior_set?/1` now delegates here.
  @doc """
  Does `kind_module` declare `requires_explicit_behavior_set?/0 == true`?

  True only for the session Kind(s) that require an explicit `:kind_base`
  capture on every instance (scopes `effective_set/2`'s nil-guard). Defaults to
  `false` for every Kind without the optional callback.
  """
  @spec requires_explicit_behavior_set?(module()) :: boolean()
  def requires_explicit_behavior_set?(kind_module) when is_atom(kind_module) do
    Code.ensure_loaded?(kind_module) and
      function_exported?(kind_module, :requires_explicit_behavior_set?, 0) and
      kind_module.requires_explicit_behavior_set?()
  end

  # Behavior set for an ABSENT/`nil` `:kind_base` instance (PR-6, §3.5). Default
  # = `behaviors_of/1` (byte-identical pre-PR-6). A SUPERSET Kind overrides it
  # to its BASE subset so a flavor-only declared Behavior never pollutes legacy
  # nil-`:kind_base` agents. Extracted from `Ezagent.Kind` (oversized-module arch
  # gate, 2026-06-23) — `Ezagent.Kind.nil_capture_behavior_set/1` delegates here.
  @doc """
  The behavior set for an ABSENT / `nil` `:kind_base` capture.

  Defaults to `Ezagent.Kind.behaviors_of/1` (byte-identical to pre-PR-6); a
  superset Kind (e.g. `Entity.Agent`) overrides `nil_capture_behavior_set/0` to
  return its BASE subset so a flavor-only declared Behavior never pollutes a
  legacy nil-`:kind_base` instance.
  """
  @spec nil_capture_behavior_set(module()) :: [module()]
  def nil_capture_behavior_set(kind_module) when is_atom(kind_module) do
    if Code.ensure_loaded?(kind_module) and
         function_exported?(kind_module, :nil_capture_behavior_set, 0) do
      kind_module.nil_capture_behavior_set()
    else
      Ezagent.Kind.behaviors_of(kind_module)
    end
  end

  @doc """
  The set `init_fresh_first_spawn/2` enumerates at FIRST spawn, computed from
  spawn args (no slice state yet). Declaration order preserved; base behaviors
  appended (deduped).

  Legacy-sentinel rule (codex CRITICAL): an ABSENT `:behaviors` key →
  full declared list; a PRESENT list (even `[]`) → `(list ∩ declared)`. So
  an explicit `%{behaviors: []}` is NEVER expanded to the declared superset.
  """
  @spec init_set(module(), map()) :: [module()]
  def init_set(kind_module, args) when is_atom(kind_module) and is_map(args) do
    declared = Ezagent.Kind.behaviors_of(kind_module)

    chosen =
      case Map.fetch(args, :behaviors) do
        # ABSENT key → legacy static Kind → the Kind's nil-capture default
        # (PR-6). For every Kind without a `nil_capture_behavior_set/0`
        # override this IS `behaviors_of/1` (= `declared`), so the legacy
        # expansion is byte-identical. A superset Kind (Entity.Agent) returns
        # its BASE subset here so legacy nil-`:kind_base` agents never gain a
        # flavor-only declared behavior.
        :error ->
          nil_capture_behavior_set(kind_module)

        # PRESENT list (INCLUDING []). RF-1 (generalized keystone): keep
        # `declared ∩ requested` (declared order — byte-identical to pre-RF-1)
        # AND ALSO requested members that are NOT declared but ARE validated
        # real Behaviors (recipe-loaded role behaviors on a generic host Kind
        # that declares nothing flavor/role-specific). A declared-but-scoped-out
        # behavior stays excluded (it is not in `requested`) → P1 subset-denial
        # holds. `real_behavior?/1` is the trust check that replaces "∩ declared"
        # (Recipe.new/1 validates recipe behaviors are real Behaviors); authz still
        # gates every action, so presence in the set grants NO privilege.
        {:ok, list} when is_list(list) ->
          requested = MapSet.new(list)
          declared_part = Enum.filter(declared, &MapSet.member?(requested, &1))
          declared_set = MapSet.new(declared)

          extra_part =
            Enum.filter(list, fn b ->
              not MapSet.member?(declared_set, b) and real_behavior?(b)
            end)

          declared_part ++ extra_part
      end

    Enum.uniq(chosen ++ base_behaviors())
  end

  @doc """
  The effective behavior set for this instance, declaration order preserved.

  Legacy-sentinel rule (codex CRITICAL), symmetric with `init_set/2`: the
  captured value read back from `:kind_base` is the sentinel `nil` for an
  absent-args (legacy static) instance → full declared list; a PRESENT
  captured list (even `[]`) → `(list ∩ declared)`. An explicit captured `[]`
  is NEVER expanded to the declared superset.
  """
  @spec effective_set(module(), %{atom() => map()}) :: [module()]
  def effective_set(kind_module, slice_state) when is_atom(kind_module) and is_map(slice_state) do
    declared = Ezagent.Kind.behaviors_of(kind_module)
    captured = KindBase.behaviors_in_slice(Map.get(slice_state, :kind_base))

    chosen =
      case captured do
        # Legacy sentinel (absent-args instance, or missing slice).
        nil ->
          # P5-0b SCOPED nil-guard: for a Kind that requires an explicit set
          # (the session Kind(s)), a nil capture is INVALID — fail loud rather
          # than expand to the declared (post-P5-1: union) list and silently
          # break P1's per-instance denial. For every other (legacy static)
          # Kind, the sentinel nil → full declared list is the intentional
          # compat path and is UNCHANGED.
          if requires_explicit_behavior_set?(kind_module) do
            raise Ezagent.Kind.BehaviorSet.MissingKindBaseError,
              kind_module: kind_module,
              message:
                "#{inspect(kind_module)} requires an explicit :kind_base behavior " <>
                  "set on every instance, but this instance's :kind_base is nil/missing. " <>
                  "Thread `:behaviors` through the spawn path (P5-0b) or backfill the " <>
                  "snapshot (`mix ezagent.kind_base.backfill`, P5-0)."
          end

          # PR-6 — the Kind's nil-capture default (= `behaviors_of/1` for every
          # Kind without an override; the BASE subset for a superset Kind like
          # Entity.Agent). Symmetric with `init_set/2`'s absent-key branch.
          nil_capture_behavior_set(kind_module)

        # PRESENT captured list (INCLUDING []). RF-1: symmetric with init_set —
        # keep `declared ∩ captured` (declared order) AND captured members that
        # are undeclared-but-real Behaviors (recipe-loaded). Scoped-out declared
        # behaviors stay excluded → P1 subset-denial holds; cold-restart
        # rehydrates the identical set from the persisted `:kind_base`.
        list when is_list(list) ->
          captured_set = MapSet.new(list)
          declared_part = Enum.filter(declared, &MapSet.member?(captured_set, &1))
          declared_set = MapSet.new(declared)

          extra_part =
            Enum.filter(list, fn b ->
              not MapSet.member?(declared_set, b) and real_behavior?(b)
            end)

          declared_part ++ extra_part
      end

    Enum.uniq(chosen ++ base_behaviors())
  end

  # RF-1 trust check: a module is admissible into an instance's behavior set iff
  # it is a loaded, validated real Behavior (same predicate `Ezagent.Agent.Recipe` uses
  # at recipe-validation time). This REPLACES the prior "∩ behaviors_of" gate for
  # undeclared recipe-loaded behaviors; declared behaviors are unaffected. authz
  # (`required_caps()` + caller caps) remains the independent privilege gate.
  defp real_behavior?(mod) when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) do
    Code.ensure_loaded?(mod) and Ezagent.ActionSet.new_style?(mod)
  end

  defp real_behavior?(_), do: false

  @doc """
  Resolve `action → behavior` for an instance: STATIC-FIRST, then per-instance.

  RF-1 (role-foundation, generalized keystone): the `{kind,action}`
  `BehaviorRegistry` resolves declared + registry-only behaviors to their
  CANONICAL module first (so a recipe-loaded behavior can NEVER shadow
  `IdentityAdmin`/`Manage`/etc.); only a genuinely-unregistered action falls
  back to this instance's loaded set (a recipe-loaded UNDECLARED behavior whose
  `actions/0` includes `action`). The central verifier independently gates every
  action, so presence in the set grants NO privilege.
  """
  @spec resolve_action(module(), atom(), %{atom() => map()}) ::
          {:ok, module()} | {:error, {:unknown_action, atom()}}
  def resolve_action(kind_module, action, slice_state) do
    case Ezagent.BehaviorRegistry.lookup(kind_module, action) do
      {:ok, behavior_module} ->
        {:ok, behavior_module}

      :error ->
        case per_instance_behavior(kind_module, action, slice_state) do
          nil -> {:error, {:unknown_action, action}}
          behavior_module -> {:ok, behavior_module}
        end
    end
  end

  # `effective_set/2` can raise MissingKindBaseError for a Kind that requires an
  # explicit set with a nil capture — preserve the prior unknown-action semantics
  # on the registry-miss path (→ nil → :unknown_action) rather than newly
  # raising. Guard `actions/0` (e.g. KindBase has none).
  defp per_instance_behavior(kind_module, action, slice_state) do
    eff =
      try do
        effective_set(kind_module, slice_state)
      rescue
        Ezagent.Kind.BehaviorSet.MissingKindBaseError -> []
      end

    Enum.find(eff, fn b -> function_exported?(b, :actions, 0) and action in b.actions() end)
  end

  @doc "Is `behavior` a member of `effective_set`?"
  @spec member?(module(), [module()]) :: boolean()
  def member?(behavior, effective_set) when is_atom(behavior) and is_list(effective_set) do
    behavior in effective_set
  end

  @doc """
  The instance's SLICE-BEARING behaviors — `effective_set/2` MINUS the universal
  behaviors (`UniversalBehaviors.all/0`, today `Manage`).

  Universal behaviors are DISPATCH-ONLY: they are universal-by-construction,
  resolve via the registry fallback, read no per-instance slice, and pre-P1 were
  NEVER in any Kind's `behaviors_of/0`. They therefore participate in NEITHER
  slice materialization NOR the per-instance lifecycle enumerations (post_init /
  on_ready / activate / terminate / destroy / handle_signal / prune / reconcile).
  Running their Lifecycle hooks would crash (no materialized slice → the
  `%{state: _}` engine callbacks have no clause for `%{}`) and is semantically
  wrong (they are not per-instance state).

  Every runtime SLICE/LIFECYCLE entry point (E1–E7) enumerates THIS set; only the
  DISPATCH membership gate (E9) uses the full `effective_set/2` (with its own
  explicit universal exemption). `KindBase` IS slice-bearing (it owns the
  persisted `:kind_base` slice) and stays in this set.
  """
  @spec materialized_set(module(), %{atom() => map()}) :: [module()]
  def materialized_set(kind_module, slice_state)
      when is_atom(kind_module) and is_map(slice_state) do
    universal = MapSet.new(Ezagent.UniversalBehaviors.all())

    kind_module
    |> effective_set(slice_state)
    |> Enum.reject(&MapSet.member?(universal, &1))
  end

  # Slice-owner map: which Behavior module OWNS each slice key. Single
  # source of truth for the closure resolver. Derived from each
  # session-relevant Behavior's `state_slice/0`.
  #
  # C5 §3.4 non-port findings — this table (and `@required_reads` below)
  # hard-coded concrete domain/plugin ActionSet modules INSIDE the framework
  # (module-ATOM refs the standalone compile would not flag). INVERTED to
  # registration data: the values now live in core-side wiring
  # (`Ezagent.Kind.Adapters.wire!/0`, app env `:ezagent_actor`) and are read
  # here at runtime — the framework source names no domain ActionSet.
  @spec slice_owners() :: %{atom() => module()}
  defp slice_owners, do: Application.fetch_env!(:ezagent_actor, :slice_owners)

  # Per-reader required-vs-optional classification of each `reads_siblings`
  # key. A key absent from a reader's entry defaults to :optional (preserves
  # the soft `%{}` default the runtime injects today — `context.ex`).
  # (C5 §3.4: registration data, see `slice_owners/0` above.)
  @spec required_reads() :: %{module() => %{atom() => :required | :optional}}
  defp required_reads, do: Application.fetch_env!(:ezagent_actor, :required_reads)

  @type closure_error ::
          {:missing_required_siblings, [{module(), atom()}]}
          | {:unknown_required_slice_owner, atom()}

  @doc """
  Validate a behavior set is closed under its REQUIRED sibling reads.

  Closure is checked by OWNER MODULE, not by slice-key presence: for each
  reader's REQUIRED `reads_siblings` key we look up the key's OWNING
  behavior module in `@slice_owners` and require THAT EXACT MODULE to be a
  member of the set. A different behavior that merely happens to declare
  the same `state_slice/0` key does NOT satisfy the dependency — a
  slice-key collision must never falsely close the set (otherwise a reader
  like `Turn` could initialize/dispatch against a fake/incompatible
  `:surface` owner, defeating the dependency-closed invariant).

  Fails loud ONLY on a missing required sibling OWNER; optional reads keep
  the soft `%{}` default (no failure). A required key with NO entry in
  `@slice_owners` is a programming error (a new required dep added without
  registering its owner) and fails loud with
  `{:error, {:unknown_required_slice_owner, key}}` so it can never silently
  pass closure.

  Returns `:ok` on success, or
  `{:error, {:missing_required_siblings, [{reader, key}]}}` /
  `{:error, {:unknown_required_slice_owner, key}}` on failure.
  """
  @spec resolve_closure([module()]) :: :ok | {:error, closure_error()}
  def resolve_closure(set) when is_list(set),
    do: resolve_closure_for(set, required_reads(), slice_owners())

  @doc """
  Map-injectable core of `resolve_closure/1`. The production call passes the
  module's `@required_reads` and `@slice_owners`; tests pass synthetic maps
  to exercise the unknown-required-key branch deterministically without
  mutating the production maps. Closure is OWNER-MODULE based: a required
  key's owner module (per `slice_owners`) MUST be a set member — a mere
  slice-key collision never closes it.
  """
  @spec resolve_closure_for([module()], map(), map()) :: :ok | {:error, closure_error()}
  def resolve_closure_for(set, required_reads, slice_owners)
      when is_list(set) and is_map(required_reads) and is_map(slice_owners) do
    members = MapSet.new(set)

    required_pairs =
      for reader <- set,
          {key, :required} <- Map.to_list(Map.get(required_reads, reader, %{})),
          do: {reader, key}

    # Fail loud on a required key whose owner module is not registered in
    # slice_owners — a new required dep must declare its owner.
    unknown =
      Enum.find(required_pairs, fn {_reader, key} ->
        not Map.has_key?(slice_owners, key)
      end)

    cond do
      unknown != nil ->
        {_reader, key} = unknown
        {:error, {:unknown_required_slice_owner, key}}

      true ->
        missing =
          for {reader, key} <- required_pairs,
              owner = Map.fetch!(slice_owners, key),
              not MapSet.member?(members, owner),
              do: {reader, key}

        case missing do
          [] -> :ok
          _ -> {:error, {:missing_required_siblings, missing}}
        end
    end
  end

  @doc """
  Raising form of `resolve_closure/1`, returning the set unchanged on
  success so it can sit inline in a pipe at the init chokepoint
  (`Snapshot.init_fresh_first_spawn/2` at first spawn; also on the persisted
  effective set in the reload branch of `load_with_fallback/3`). RAISES
  `UnclosedSetError` (which aborts the spawn before any `create`/`init_slice`
  runs) when a required sibling owner is missing.

  This is the load-bearing enforcement of P1.1 (codex CRITICAL finding 1):
  the closure is checked at the SAME point the slices are about to be
  materialized, so an unclosed set NEVER reaches `init_slice` and NEVER
  persists a partial snapshot.
  """
  @spec validate_closure!([module()]) :: [module()]
  def validate_closure!(set) when is_list(set),
    do: validate_closure_for!(set, required_reads(), slice_owners())

  @doc """
  Map-injectable raising form (production passes the module's
  `@required_reads`/`@slice_owners`; tests inject synthetic maps to drive
  the unknown-required-key branch). Raises `UnclosedSetError` on a missing
  required sibling OWNER or an unknown required slice key.
  """
  @spec validate_closure_for!([module()], map(), map()) :: [module()]
  def validate_closure_for!(set, required_reads, slice_owners)
      when is_list(set) and is_map(required_reads) and is_map(slice_owners) do
    case resolve_closure_for(set, required_reads, slice_owners) do
      :ok ->
        set

      {:error, {:missing_required_siblings, missing}} ->
        raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
          message:
            "behavior set is not closed under required sibling reads — " <>
              "missing required sibling owner(s): " <>
              Enum.map_join(missing, ", ", fn {reader, key} ->
                owner = Map.fetch!(slice_owners, key)
                "#{inspect(reader)} requires slice :#{key} (owner #{inspect(owner)})"
              end),
          missing: missing

      {:error, {:unknown_required_slice_owner, key}} ->
        # A REQUIRED reads_siblings key with no slice_owners entry is a
        # programming error (new required dep added without registering its
        # owner module). Fail loud so it can never silently pass closure.
        raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
          message:
            "behavior set closure cannot be resolved — required slice " <>
              ":#{key} has no owner module registered in @slice_owners",
          missing: [{:unknown_required_slice_owner, key}]
    end
  end

  @doc "The owning Behavior module for a slice key (or nil)."
  @spec owner_of(atom()) :: module() | nil
  def owner_of(slice_key) when is_atom(slice_key), do: Map.get(slice_owners(), slice_key)
end
