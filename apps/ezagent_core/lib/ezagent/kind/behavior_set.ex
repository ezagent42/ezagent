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

  alias Ezagent.Behavior.KindBase

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
        # ABSENT key → legacy static Kind → full declared list.
        :error ->
          declared

        # PRESENT list (INCLUDING []) → intersect with declared, order-preserved.
        {:ok, list} when is_list(list) ->
          requested = MapSet.new(list)
          Enum.filter(declared, &MapSet.member?(requested, &1))
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
        # Legacy sentinel (absent-args instance, or missing slice) → declared.
        nil ->
          declared

        # PRESENT captured list (INCLUDING []) → intersect with declared.
        list when is_list(list) ->
          captured_set = MapSet.new(list)
          Enum.filter(declared, &MapSet.member?(captured_set, &1))
      end

    Enum.uniq(chosen ++ base_behaviors())
  end

  @doc "Is `behavior` a member of `effective_set`?"
  @spec member?(module(), [module()]) :: boolean()
  def member?(behavior, effective_set) when is_atom(behavior) and is_list(effective_set) do
    behavior in effective_set
  end
end
