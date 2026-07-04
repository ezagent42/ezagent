defmodule Ezagent.ActionSet.Effects do
  @moduledoc false

  @type mfa_or_fun ::
          (... -> term())
          | {module(), atom()}

  @type effect ::
          {:set, atom(), term()}
          | {:set_transient, atom(), term()}
          | {:emit, atom(), map()}
          | {:dispatch, Ezagent.Cmd.t()}
          # P2.5c — a re-entrant dispatch the runtime COLLECTS + resolves
          # (substitute_refs + enrich) but does NOT execute during the
          # handler. `Kind.Server` runs it via `Router.dispatch` ONLY after
          # the parent slice durably commits (and SKIPS it on a commit
          # failure). Closes the rev4 ordering bug: a settlement/delivery
          # must not outlive a failed parent-turn commit.
          | {:dispatch_after_commit, Ezagent.Cmd.t()}
          | {:dispatch_returning, Ezagent.Cmd.t(), keyword()}
          | {:notify, String.t(), term()}
          | {:effect, mfa_or_fun(), [term()]}
          | {:effect_returning, mfa_or_fun(), [term()], keyword()}
          | {:terminate, :self | URI.t()}
          | {:saga, term()}
          | {:halt, term()}

  @spec apply_effects([effect()], map()) ::
          {:ok,
           %{
             state: map(),
             events: list(),
             dispatches: list(),
             dispatches_after_commit: list(),
             dispatches_returning: list(),
             notifies: list(),
             terminations: list(),
             saga: term() | nil,
             returning: map()
           }}
          | {:halt, term(), map()}
  def apply_effects(effects, state) when is_list(effects) and is_map(state) do
    initial = %{
      state: state,
      events: [],
      dispatches: [],
      # P2.5c — post-parent-commit dispatches. Collected here, NOT
      # executed; `Kind.Server` runs them after the parent slice durably
      # commits. See the `{:dispatch_after_commit, _}` effect type.
      dispatches_after_commit: [],
      notifies: [],
      terminations: [],
      effects: [],
      effects_returning: [],
      # 2026-05-29 dispatch_returning SPEC §4a — collected during
      # bucketing alongside `:effect_returning`. The executor
      # (Kind.Runtime) is responsible for running each entry through
      # `Router.dispatch/1` synchronously, binding the result into
      # the shared `returning` map BEFORE downstream
      # dispatches/notifies/events are flushed. Holding the bucket
      # in `apply_effects/2` rather than running it inline keeps
      # this module pure (no Router dependency) — same separation
      # we use for the existing buckets.
      dispatches_returning: [],
      saga: nil,
      returning: %{}
    }

    case bucket_by_phase(effects, initial) do
      {:halt, reason, partial} -> {:halt, reason, partial}
      {:ok, bucketed} -> apply_buckets(bucketed)
    end
  end

  # First pass: separate effects into phase buckets, preserving
  # declared-order within each phase. Also catches `{:halt, _}`.
  defp bucket_by_phase([], acc), do: {:ok, acc}

  defp bucket_by_phase([effect | rest], acc) do
    case effect do
      {:halt, reason} ->
        {:halt, reason, acc}

      {:set, _key, _value} = e ->
        bucket_by_phase(rest, Map.update!(acc, :events, &[{:__set__, e} | &1]) |> bucket_set(e))

      # Lifecycle Phase A (SPEC 2026-05-29 §9 OQ-2 + §10-R2) —
      # `{:set_transient, key, value}` writes into the Lifecycle slice's
      # `:transients` sub-map. Like `:set`, it is reduced into the
      # in-memory accumulator BEFORE the caller commits (R10-2: both
      # containers advance together pre-commit; if the durable commit of
      # `state` fails, the caller keeps the prior slice and neither
      # container advances — see `Kind.Server.commit_and_notify/3`).
      # `transients` is NEVER serialized (stripped at the snapshot
      # boundary, `Ezagent.Kind.Snapshot.strip_transients/1`), so a
      # `:set_transient` carries no durability promise — it lives in the
      # host GenServer's memory until the next stop, then is rebuilt by
      # `activate/2`.
      #
      # We deliberately keep it OUT of the `:events` ordering list (it is
      # a pure container reduction, not an audit-visible state event) and
      # OUT of every side-effect bucket. It only mutates the accumulator
      # `state` (the two-container slice) in place.
      {:set_transient, _key, _value} = e ->
        bucket_by_phase(rest, bucket_set_transient(acc, e))

      {:emit, _type, _payload} = e ->
        bucket_by_phase(rest, Map.update!(acc, :events, &[e | &1]))

      {:effect_returning, _fn, _args, _opts} = e ->
        bucket_by_phase(rest, Map.update!(acc, :effects_returning, &[e | &1]))

      {:effect, _fn, _args} = e ->
        bucket_by_phase(rest, Map.update!(acc, :effects, &[e | &1]))

      {:dispatch, %Ezagent.Cmd{}} = e ->
        bucket_by_phase(rest, Map.update!(acc, :dispatches, &[e | &1]))

      # P2.5c — collect a post-parent-commit dispatch into its own bucket.
      # NOT executed here (this module is pure — no Router dependency) and
      # NOT executed by `execute_buckets/2` either; the runtime resolves it
      # (same substitute_refs + enrich as `:dispatch`) and returns it so
      # `Kind.Server` can run it AFTER the parent slice durably commits.
      {:dispatch_after_commit, %Ezagent.Cmd{}} = e ->
        bucket_by_phase(rest, bucket_dispatch_after_commit(acc, e))

      # 2026-05-29 dispatch_returning SPEC §3 — `:dispatch_returning`
      # MUST carry a Cmd struct + a `bind_as:` atom. Validate shape
      # at bucket time so a malformed effect surfaces with a clear
      # ArgumentError instead of a runtime KeyError inside the
      # executor's Router.dispatch call.
      {:dispatch_returning, %Ezagent.Cmd{}, opts} = e when is_list(opts) ->
        case Keyword.fetch(opts, :bind_as) do
          {:ok, name} when is_atom(name) ->
            bucket_by_phase(rest, Map.update!(acc, :dispatches_returning, &[e | &1]))

          _ ->
            raise ArgumentError,
                  "Ezagent.ActionSet.apply_effects/2 :dispatch_returning requires " <>
                    "an atom `:bind_as` option; got: #{inspect(opts)}"
        end

      {:notify, _topic, _payload} = e ->
        bucket_by_phase(rest, Map.update!(acc, :notifies, &[e | &1]))

      {:terminate, _target} = e ->
        bucket_by_phase(rest, Map.update!(acc, :terminations, &[e | &1]))

      {:saga, _saga} = e ->
        bucket_by_phase(rest, %{acc | saga: e})

      other ->
        raise ArgumentError,
              "Ezagent.ActionSet.apply_effects/2 encountered unknown effect: #{inspect(other)}"
    end
  end

  # Apply `:set` effects to state in-place during the first pass so
  # downstream effect-substitution can see them via {:ref, ...}.
  #
  # Lifecycle Phase A (SPEC 2026-05-29 §0.1) — two-container awareness.
  # When the slice has the Lifecycle two-container shape (`%{state: _,
  # transients: _}`), `{:set, key, value}` writes into the `:state`
  # sub-map (the persistent container). For a legacy flat slice (no
  # `:transients` sub-key) the write is flat, exactly as before — so
  # every existing Behavior is byte-for-byte unaffected.
  defp bucket_set(acc, {:set, key, value}) do
    %{acc | state: put_state_field(acc.state, key, value)}
  end

  # P2.5c — accumulate a `{:dispatch_after_commit, cmd}` effect (the Cmd,
  # unwrapped) into its own bucket, prepended for O(1) collection and
  # reversed to declared order in `apply_buckets/1`.
  defp bucket_dispatch_after_commit(acc, {:dispatch_after_commit, %Ezagent.Cmd{} = cmd}) do
    %{acc | dispatches_after_commit: [cmd | acc.dispatches_after_commit]}
  end

  # Lifecycle Phase A (SPEC 2026-05-29 §9 OQ-2 + §10-R2) — apply a
  # `{:set_transient, key, value}` into the slice's `:transients`
  # sub-map. Only valid on a Lifecycle two-container slice; a
  # `:set_transient` against a flat (legacy) slice is a programmer error
  # (a legacy Behavior has no transients container) and raises, per
  # `feedback_let_it_crash_no_workarounds` — no silent shim.
  defp bucket_set_transient(acc, {:set_transient, key, value}) do
    %{acc | state: put_transient_field(acc.state, key, value)}
  end

  defp put_state_field(%{state: st, transients: _tr} = slice, key, value) when is_map(st) do
    %{slice | state: Map.put(st, key, value)}
  end

  defp put_state_field(flat_slice, key, value) when is_map(flat_slice) do
    Map.put(flat_slice, key, value)
  end

  defp put_transient_field(%{state: _st, transients: tr} = slice, key, value) when is_map(tr) do
    %{slice | transients: Map.put(tr, key, value)}
  end

  defp put_transient_field(other, key, _value) do
    raise ArgumentError,
          "{:set_transient, #{inspect(key)}, _} requires a Lifecycle two-container " <>
            "slice (`%{state: _, transients: _}`); got a flat slice: #{inspect(other)}. " <>
            "Only modules using `use Ezagent.Lifecycle` may emit :set_transient effects."
  end

  # Second pass: filter the synthetic `__set__` markers out of
  # `events` (they were only there to preserve declared-order; the
  # real :set state mutation already happened in `bucket_set`).
  # Then reverse all buckets to restore declared order.
  defp apply_buckets(acc) do
    events =
      acc.events
      |> Enum.reverse()
      |> Enum.reject(&match?({:__set__, _}, &1))

    dispatches = Enum.reverse(acc.dispatches)
    # P2.5c — restore declared order; the runtime resolves + returns these
    # for `Kind.Server` to run post-commit (they hold raw `%Cmd{}` structs,
    # NOT `{:dispatch_after_commit, _}` tuples — unwrapped at bucket time).
    dispatches_after_commit = Enum.reverse(acc.dispatches_after_commit)
    notifies = Enum.reverse(acc.notifies)
    terminations = Enum.reverse(acc.terminations)
    effects = Enum.reverse(acc.effects)
    effects_returning = Enum.reverse(acc.effects_returning)
    # 2026-05-29 dispatch_returning SPEC §4a — the executor consumes
    # this list. We restore declared order so the executor's Router
    # calls happen in the same order the handler declared them.
    dispatches_returning = Enum.reverse(acc.dispatches_returning)

    # Execute :effect_returning calls in declared order, binding
    # returns into `returning` map. Subsequent effects' `{:ref,
    # name, path}` references substitute against this map.
    {returning, returning_errors} =
      Enum.reduce(effects_returning, {acc.returning, []}, fn
        {:effect_returning, fun, args, opts}, {bound, errs} ->
          name = Keyword.fetch!(opts, :bind_as)

          result =
            case fun do
              f when is_function(f) -> apply(f, args)
              {m, f} when is_atom(m) and is_atom(f) -> apply(m, f, args)
            end

          {Map.put(bound, name, result), errs}
      end)

    # Execute :effect (fire-and-forget) — wrap in try so a failing
    # effect surfaces in the returned map but doesn't crash the
    # caller's reduce.
    effect_errors =
      Enum.reduce(effects, [], fn {:effect, fun, args}, errs ->
        try do
          case fun do
            f when is_function(f) -> apply(f, args)
            {m, f} when is_atom(m) and is_atom(f) -> apply(m, f, args)
          end

          errs
        rescue
          e -> [{:effect_failed, fun, args, e} | errs]
        end
      end)

    # Substitute {:ref, name, path} in dispatches/notifies/events
    # against `returning`.
    events = Enum.map(events, &substitute_refs(&1, returning))
    dispatches = Enum.map(dispatches, &substitute_refs(&1, returning))
    # P2.5c — first-pass ref substitution (effect_returning bindings),
    # mirroring `:dispatch`. The runtime's `execute_buckets/2` does the
    # second pass (dispatch_returning bindings) + enrichment before returning
    # these to `Kind.Server`.
    dispatches_after_commit = Enum.map(dispatches_after_commit, &substitute_refs(&1, returning))
    notifies = Enum.map(notifies, &substitute_refs(&1, returning))

    {:ok,
     %{
       state: acc.state,
       events: events,
       dispatches: dispatches,
       # P2.5c — raw `%Cmd{}` structs to be run post-parent-commit by
       # `Kind.Server`. `apply_effects/2` does NOT execute them.
       dispatches_after_commit: dispatches_after_commit,
       # 2026-05-29 dispatch_returning SPEC §4a — surface the
       # collected `:dispatch_returning` effects to the executor.
       # `apply_effects/2` does NOT run them itself (that would
       # require a Router dependency in this pure module). The
       # caller (Kind.Runtime.apply_new_contract_effects/4) runs
       # each entry synchronously via `Router.dispatch/1`, binds
       # the result into `returning`, and THEN substitutes refs in
       # the dispatches/notifies/events lists (which `apply_effects/2`
       # has already substituted using ONLY `:effect_returning`
       # bindings). The double-substitution is the executor's
       # responsibility.
       dispatches_returning: dispatches_returning,
       notifies: notifies,
       terminations: terminations,
       saga: acc.saga,
       returning: returning,
       errors: Enum.reverse(effect_errors) ++ Enum.reverse(returning_errors)
     }}
  end

  # Recursive ref substitution — walks maps, lists, tuples.
  @doc false
  def substitute_refs({:ref, name, path}, bound) when is_atom(name) and is_list(path) do
    case Map.fetch(bound, name) do
      {:ok, value} -> get_in_safe(value, path)
      :error -> {:ref, name, path}
    end
  end

  def substitute_refs({:ref, name}, bound) when is_atom(name) do
    case Map.fetch(bound, name) do
      {:ok, value} -> value
      :error -> {:ref, name}
    end
  end

  def substitute_refs(%URI{} = uri, _bound), do: uri

  def substitute_refs(%MapSet{} = ms, _bound), do: ms

  def substitute_refs(%_struct{} = s, bound) do
    # For non-URI/MapSet structs (e.g. Ezagent.Cmd), walk fields.
    s
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, substitute_refs(v, bound)} end)
    |> Enum.into(%{})
    |> then(&struct!(s.__struct__, &1))
  end

  def substitute_refs(m, bound) when is_map(m) do
    Map.new(m, fn {k, v} -> {k, substitute_refs(v, bound)} end)
  end

  def substitute_refs(l, bound) when is_list(l) do
    Enum.map(l, &substitute_refs(&1, bound))
  end

  def substitute_refs(t, bound) when is_tuple(t) do
    t
    |> Tuple.to_list()
    |> Enum.map(&substitute_refs(&1, bound))
    |> List.to_tuple()
  end

  def substitute_refs(other, _bound), do: other

  defp get_in_safe(value, []), do: value

  defp get_in_safe(value, [k | rest]) when is_map(value) do
    case Map.fetch(value, k) do
      {:ok, v} -> get_in_safe(v, rest)
      :error -> nil
    end
  end

  defp get_in_safe(_, _), do: nil
end
