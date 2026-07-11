defmodule Ezagent.Kind.Runtime do
  @moduledoc """
  In-process dispatch flow inside a Kind GenServer.

  ## New-contract effect execution order (Phase 1.5b)

  When the dispatched Behavior is new-style (`use Ezagent.ActionSet`),
  the handler's `{:ok, result, effects}` return runs through
  `Ezagent.ActionSet.apply_effects/2` and then THIS module executes
  each effect bucket against the rest of the system in the following
  fixed order:

      State → Halt-check → Saga → DispatchesReturning → Dispatches
        → Notifies → Events → Terminations

  (`DispatchesReturning` was inserted by SPEC
  `2026-05-29-dispatch-returning-effect.md` — it runs synchronous
  `Router.dispatch/1` calls whose return value binds into the shared
  `returning` map for downstream `{:ref, ...}` substitution. It runs
  AFTER saga and BEFORE the regular `:dispatch` bucket so a returning
  dispatch's value is available to any `{:ref, ...}` reference in the
  remaining buckets.)

  Rationale (per SPEC `2026-05-28-router-behavior-kind-architecture.md`
  §4.4 + Phase 1.5b directive):

  - **State** — `:set` effects are eagerly applied to `slice` inside
    `apply_effects/2` so subsequent in-handler `{:ref, ...}` substitutions
    see the new values. The framework writes the new slice via the
    standard snapshot path (commit-then-notify in `Kind.Server`).
  - **Halt-check** — `apply_effects/2` short-circuits on `{:halt, _}`
    and returns `{:halt, reason, partial}`. Remaining effects are
    NOT executed; we map the halt to `{:error, {:halt, reason}}` so
    the caller sees the dispatch as a failure and SnapshotStore never
    sees the would-be new slice.
  - **Saga** — runs BEFORE cross-Kind dispatches because the saga
    IS the orchestration boundary; its own compensation must not
    race with sibling dispatches.
  - **Dispatches** — sequential, in declared order. Each is a
    `%Ezagent.Cmd{}` re-entered via `Ezagent.Router.dispatch/1`. If
    any dispatch returns `{:error, _}`, remaining dispatches/notifies/
    events/terminations are skipped and the error propagates up.
  - **Notifies** — `Phoenix.PubSub.broadcast(EzagentCore.PubSub, …)`.
    Fire-and-forget; never blocks. Declared order preserved but no
    happens-before guarantee w.r.t. subscribers.
  - **Events** — `Ezagent.EventLog.append/4`. Audit failures DO
    NOT halt the dispatch (audit is observational); a warning is
    logged and the pipeline continues.
  - **Terminations** — last so audit + notify have already happened
    against the still-live Kind. Idempotent via
    `Ezagent.Kind.terminate/1` (no-op when the URI is already gone).

  The handler return + effect grammar live in `Ezagent.ActionSet` —
  this module is the EXECUTOR; the SCHEMA is over there.

  ## Original dispatch flow

  Runs Appendix A steps 5-10 once the invocation has been routed to a
  specific pid by `Ezagent.Invocation.dispatch/1`:

  - **5**: `BehaviorRegistry.lookup({kind_module, action})`
  - **5.5**: authz gate — `Ezagent.Capability.matches?` against ctx.caps
    (Phase 3d, P3-D6). Emits `[:ezagent, :authz, :granted|:denied]`.
    `authz_check/5` returns `{:ok, matched_cap}` — the capability that
    authorized (or `nil` when via a slice-held cap / rule / exempt action)
    — threaded into the cross-workspace Receipt (step 10.5, `Runtime.Receipt`).
  - **5.6**: workspace isolation — caller & target share a workspace, OR
    caller holds a cross-workspace cap (`workspace_uri: :any`). Phase 9 PR-4
    (SPEC v3 §5). Bypass: `:vm_internal` caller, cross-cutting-scheme target
    (`workspace_of → :any`), or a held cross-workspace cap. Returns
    `{:error, :cross_workspace_denied}` — distinct from `:unauthorized`
    (invariant 9) so transports surface a different message + reaction.
  - **5.7**: validate args against `behavior.interface()[action].args`
  - **6-9**: extract slice → invoke → shape return → `put_in` new slice
  - **10**: emit `[:ezagent, :invoke, :stop]` telemetry
  - **10.5**: on a cross-workspace success, `Runtime.Receipt.maybe_emit/5`
    records one durable `:receipt` fact (reputation exhaust; never blocks).

  Per DECISIONS P1-D2: this function is **defensive** about state shape —
  the shared `Kind.Server` hosts multiple Kind types with differing slice
  shapes, so it uses `Map.get` rather than struct field access.
  """

  require Logger

  alias Ezagent.Kind.Runtime.Receipt

  @type slice_state :: %{atom() => map()}
  # PR-N1 round-2 MEDIUM: 4th element = optional `slice_change_event` for
  # `Kind.Server` to fire AFTER `Snapshot.maybe_save/4` (was 2-/3-tuple).
  # P2.5c — 5th element: resolved+enriched `deferred` post-commit dispatches.
  @type result ::
          {:ok, slice_state(), term(), slice_change_event() | nil, [Ezagent.Cmd.t()]}
          | {:ok, slice_state(), nil, slice_change_event() | nil, [Ezagent.Cmd.t()]}
          | {:error, term()}
  @type slice_change_event :: %{
          required(:self_uri) => URI.t(),
          required(:kind_module) => module(),
          required(:action) => atom(),
          required(:slice_key) => atom(),
          required(:old_slice) => map(),
          required(:new_slice) => map(),
          required(:result) => term() | nil,
          required(:caller) => URI.t() | nil,
          required(:at) => DateTime.t(),
          # PR-N3 r4 — pre-allocated SliceChange broadcast cursor;
          # `SliceChange.emit/1` uses this instead of allocating a
          # fresh one so the envelope cursor matches the value the
          # Behavior used as the `:recent_messages` ring key.
          required(:cursor) => pos_integer()
        }

  @spec handle_dispatch(Ezagent.Invocation.t(), slice_state(), module(), URI.t()) :: result()
  def handle_dispatch(
        %Ezagent.Invocation{target: target, args: args, ctx: ctx} = _inv,
        state,
        kind_module,
        self_uri
      ) do
    started_at = System.monotonic_time(:microsecond)

    # Inject at this single point so plugins never plumb it themselves:
    # `:kind_module` + `:self_uri` (multi-Kind Behaviors branch on which Kind
    # hosts them, Phase 2), and `:session_uri` (Phase 7 PR 43 / Decision #137 —
    # what `Capability.instance_match?/2` reads for a `{:within_session, S}`
    # scope-tuple cap; pure O(1) URI parsing, no dispatch/registry).
    #
    # PR-N3 r4 (Allen 2026-05-25) — pre-allocate the `SliceChange` broadcast
    # cursor BEFORE invoke so the Behavior writes cursor-keyed slice entries that
    # match the envelope subscribers receive (`SliceChange.emit/1` reads this
    # cursor from the producer event). Burning a cursor per dispatch is fine —
    # cursors are an ordering hint, not a key (`SliceChange.Cursors` moduledoc).
    slice_change_cursor = Ezagent.SliceChange.Cursors.next(self_uri)

    enriched_ctx =
      ctx
      |> Map.put(:kind_module, kind_module)
      |> Map.put(:self_uri, self_uri)
      |> Map.put(:session_uri, derive_session_uri(target))
      |> Map.put(:slice_change_cursor, slice_change_cursor)

    with {:ok, {behavior_name_atom, action}} <- Ezagent.URI.behavior_action(target),
         {:ok, behavior_module} <-
           Ezagent.Kind.BehaviorSet.resolve_action(kind_module, action, state),
         :ok <- instance_set_gate(behavior_module, kind_module, state, target, enriched_ctx),
         # authz_check returns `{:ok, matched_cap}` (`nil` when authorized via a
         # slice-held cap / rule / exempt action) — same allow/deny decision;
         # matched_cap is the fact threaded into the cross-org Receipt below.
         {:ok, matched_cap} <-
           authz_check(kind_module, behavior_module, action, target, enriched_ctx),
         :ok <- workspace_isolation_check(behavior_module, target, enriched_ctx),
         :ok <- validate_args(behavior_module, action, args),
         slice_key <- behavior_module.state_slice(),
         slice <- Map.get(state, slice_key, %{}),
         # Allen 2026-05-26 (codex CRIT-1) — expose ONLY the sibling slices the
         # Behavior declared via `reads_sibling_slices/0` (default `[]` → no
         # `:sibling_slices` key). The wide `:all_slices` secret-read escape
         # hatch is gone; a Behavior needing a sibling slice declares it.
         invoke_ctx <- maybe_inject_sibling_slices(enriched_ctx, behavior_module, state),
         # P2.5c — 4-tuple; `deferred` threaded out as a 5-tuple to Kind.Server.
         {:ok, new_slice, result_or_nil, deferred} <-
           invoke_behavior(behavior_module, action, slice, args, invoke_ctx) do
      # Step 9 — put_in state. Snapshot wiring is Phase 1 step 3.
      new_state = Map.put(state, slice_key, new_slice)

      # Step 9.5 (SPEC v2 PR-N1) — slice-change event PREP (mutation IS the
      # notification trigger). We compute the payload here (we have the slice
      # diff) but do NOT emit: `Kind.Server` fires it AFTER `Snapshot.maybe_save/4`
      # so a PubSub outage can't roll back a persisted mutation. `self_uri` is the
      # bare INSTANCE URI (strip `?action=…`) so there's one topic per instance.
      slice_change_event =
        if slice_persistably_changed?(slice, new_slice) do
          %{
            self_uri: Ezagent.URI.instance(target),
            kind_module: kind_module,
            action: action,
            slice_key: slice_key,
            old_slice: slice,
            new_slice: new_slice,
            result: result_or_nil,
            caller: Map.get(enriched_ctx, :caller),
            at: DateTime.utc_now(),
            # PR-N3 r4 (Allen 2026-05-25) — pass the pre-allocated
            # cursor through to `SliceChange.emit/1` so the broadcast
            # envelope's `:cursor` field matches the value the
            # Behavior used as the slice ring key. See the cursor
            # allocation comment at the top of this function.
            cursor: slice_change_cursor
          }
        else
          nil
        end

      # Step 10 — telemetry.
      :telemetry.execute(
        [:ezagent, :invoke, :stop],
        %{duration_us: System.monotonic_time(:microsecond) - started_at},
        %{
          target: target,
          caller: Map.get(enriched_ctx, :caller),
          action: action,
          behavior_name: behavior_name_atom,
          behavior_module: behavior_module,
          kind_module: kind_module
        }
      )

      # Reputation Receipt (facts layer) — exhaust of the Cap-BAC flow: on the
      # cross-workspace success path, record a durable fact keyed on
      # `matched_cap`. Never breaks/slows the reply (swallows all failures;
      # return ignored). See `Ezagent.Kind.Runtime.Receipt`.
      _ = Receipt.maybe_emit(target, action, matched_cap, behavior_module, enriched_ctx)

      # 3-tuple result shape carries an optional `slice_change_event`
      # for `Kind.Server` to fire after snapshot persistence. `nil`
      # means no slice mutation happened (Behavior was read-only or
      # the new slice equalled the old). Codex PR-N1 round-2 MEDIUM.
      # P2.5c — 5-tuple: server runs `deferred` only after commit succeeds.
      case result_or_nil do
        nil -> {:ok, new_state, nil, slice_change_event, deferred}
        result -> {:ok, new_state, result, slice_change_event, deferred}
      end
    else
      {:error, reason} = err ->
        # Step 10 — error path also emits telemetry so audit sees it.
        :telemetry.execute(
          [:ezagent, :invoke, :error],
          %{duration_us: System.monotonic_time(:microsecond) - started_at},
          %{target: target, caller: Map.get(enriched_ctx, :caller), reason: reason}
        )

        err
    end
  end

  # Lifecycle Phase A (SPEC §0.1 / §10-R2, F1a) — a SliceChange must
  # fire only on a change to the PERSISTABLE view of the slice. For a
  # Lifecycle two-container slice (`%{state: _, transients: _}`) a
  # `{:set_transient, ...}`-only handler mutates ONLY `:transients`,
  # which is never persisted and never mirrored into a durable Publisher
  # ring — so it must NOT emit a SliceChange (which drives both the
  # persistence-coupled notification and the Publisher ring append).
  # We therefore compare the transients-stripped views. Legacy flat
  # slices have no `:transients` sub-key, so the strip is a no-op and
  # the comparison is byte-identical to the old `new_slice != slice`.
  defp slice_persistably_changed?(old_slice, new_slice) do
    strip_transients_one(old_slice) != strip_transients_one(new_slice)
  end

  defp strip_transients_one(%{transients: _} = slice) when is_map(slice),
    do: Map.delete(slice, :transients)

  defp strip_transients_one(other), do: other

  # RF-1: `action → behavior` resolution (static-first + per-instance fallback)
  # lives in `Ezagent.Kind.BehaviorSet.resolve_action/3` (cohesive with the
  # per-instance set logic; keeps runtime.ex under the gt_1000 LOC gate).

  # P1 (SPEC §3.1, E9) — the per-instance subset gate. Threat: a SUPERSET Kind
  # DECLARES `behaviors/0 = [Chat, Surface, …]` but a per-instance subset (the
  # persisted `:kind_base` set) excludes some — an excluded DECLARED behavior
  # must not act on that instance. So deny iff the behavior is BOTH (a) in the
  # DECLARED set (`behaviors_of/1`) AND (b) NOT in this instance's
  # `effective_set/2`. Behaviors OUTSIDE `behaviors_of/1` aren't part of the
  # subset mechanism and are NOT gated here — universal behaviors (`Manage`) and
  # registry-only behaviors (`IdentityAdmin` grant/revoke, `UserDefaultCredentialSource`,
  # …) are a separate always-available surface, still cap-gated by `authz_check`.
  defp instance_set_gate(behavior_module, kind_module, state, target, ctx) do
    declared? = behavior_module in Ezagent.Kind.behaviors_of(kind_module)

    in_instance? =
      Ezagent.Kind.BehaviorSet.member?(
        behavior_module,
        Ezagent.Kind.BehaviorSet.effective_set(kind_module, state)
      )

    if not declared? or in_instance? do
      :ok
    else
      # Carry caller + target so the `:authz, :denied` audit handler builds a
      # workspace-scoped row instead of raising on nil (which DETACHES the global
      # telemetry handler) — and so a denied dispatch leaves an audit trail.
      action =
        case Ezagent.URI.behavior_action(target) do
          {:ok, {_behavior, a}} -> a
          _ -> nil
        end

      :telemetry.execute([:ezagent, :authz, :denied], %{}, %{
        kind_module: kind_module,
        behavior_module: behavior_module,
        action: action,
        caller: Map.get(ctx, :caller),
        target: target,
        reason: :behavior_not_in_instance_set
      })

      {:error, :behavior_not_in_instance_set}
    end
  end

  # PR-CC-2-v2 chokepoint flip (SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md
  # §3 + §10(g)). Step 5.5 now:
  #
  # 1. Reads `behavior.required_caps()[action]` to get the DECLARATIVE
  #    cap shape that gates this action.
  # 2. Substitutes runtime `instance` (from target URI) + `workspace_uri`
  #    (from target via `Capability.workspace_of/1`) into the cap when
  #    its declared values are `:any`.
  # 3. Delegates the actual cap check to `Kind.holds_cap?/3` — reads the
  #    caller's identity slice via `Kind.get_slice/2` (no re-entry into
  #    `Invocation.dispatch/1`, breaks the self-list-caps recursion).
  #
  # `ctx.caps` is a PERMANENT authz route (the "PR-CC-2c removes it" plan
  # was WITHDRAWN — caps-cleanup-v1 §5.3 r2 HIGH-3). #154 made it the
  # carrier for INLINE self-authority caps (no slice home; a self-dispatch
  # reading its own slice would deadlock — see perf note below). ctx.caps =
  # caps PRESENTED with the call; holds_cap? = caps held in the slice. OR'd.
  defp authz_check(kind_module, behavior_module, action, target, ctx) do
    cap_exempt? = action in Ezagent.ActionSet.cap_exempt_actions_of(behavior_module)

    if cap_exempt? do
      :telemetry.execute([:ezagent, :authz, :exempt], %{}, %{
        kind_module: kind_module,
        action: action,
        target: target,
        caller: Map.get(ctx, :caller)
      })

      # Authorized with no matching cap to attribute (cap-exempt action).
      {:ok, nil}
    else
      needed = resolve_required_cap(kind_module, behavior_module, action, target)

      meta = %{
        kind_module: kind_module,
        behavior_module: behavior_module,
        action: action,
        target: target,
        caller: Map.get(ctx, :caller),
        needed: needed
      }

      cond do
        Map.get(ctx, :cap_issued, false) and
          behavior_module == Ezagent.ActionSet.IdentityAdmin and action == :grant_cap ->
          :telemetry.execute([:ezagent, :authz, :granted], %{}, Map.put(meta, :via_issue, true))
          {:ok, nil}

        # SPEC 2026-06-17 §3.3 PR-2 — rule-authorization branch. A `{:rule,…}`
        # grant carries `ctx.caps = []`; defer to the handler's
        # `check_grant_authorized` rule branch (enforces `rule_cap_bounded?/1`:
        # no wildcard / cross-behavior cap). `:authorization_rule` enters ctx
        # ONLY via the grep-gated `Ezagent.Identity.Grant` `{:rule,…}` tag;
        # scoped here to IdentityAdmin grant/revoke so nothing else rides it.
        is_map_key(ctx, :authorization_rule) and
          behavior_module == Ezagent.ActionSet.IdentityAdmin and
            action in [:grant_cap, :revoke_cap] ->
          :telemetry.execute([:ezagent, :authz, :granted], %{}, Map.put(meta, :via_rule, true))
          # Authorized by the rule branch — no single matching cap to attribute.
          {:ok, nil}

        is_nil(needed) ->
          :telemetry.execute([:ezagent, :authz, :denied], %{}, meta)
          {:error, :unauthorized}

        # 2026-05-26 (Allen perf bug): check ctx.caps BEFORE the holds_cap?
        # slice lookup. The slice path does `Kind.get_slice(caller_uri,
        # :identity)` via GenServer.call; when the caller dispatches to ITSELF
        # (e.g. a worker's own subscribe_from) that call deadlocks until the 5s
        # timeout. The ExternalMirrorWorker carries its OWN inline caps in
        # `ctx.caps` (its self-authority publish + session subscribe caps —
        # the deleted `system://worker-publish` principal's replacement, north
        # star / Decision #154), so ctx.caps-first avoids the self-call
        # deadlock AND runs the cheap path first; slice-resolved caps remain
        # the second-line check for ordinary user/agent dispatches.
        #
        # The ctx.caps-first SHORT-CIRCUIT is preserved: `granted_via_holds_cap?`
        # runs ONLY on a ctx.caps miss. The ctx.caps path returns the matched
        # `%Capability{}` (threaded into the cross-org Receipt); the slice path
        # returns `{:ok, nil}` (receipt falls back to the ctx.caps cross-ws cap).
        true ->
          case granted_via_ctx_caps?(ctx, needed) do
            {:ok, %Ezagent.Capability{} = cap} ->
              :telemetry.execute([:ezagent, :authz, :granted], %{}, meta)
              {:ok, cap}

            :error ->
              # `granted_via_holds_cap?` reads the CALLER's identity slice; a
              # TRANSIENT read failure raises `Ezagent.Kind.IdentityReadError`
              # (fail-loud, never a silent deny — see `default_holds_cap?/2`).
              # We run inside the TARGET Kind.Server's `handle_dispatch`, so we
              # CATCH it here and surface a DISTINCT, caller-retryable error
              # (never `:unauthorized` — no security decision on a transient)
              # rather than crashing the target session/workspace (which would
              # feed a rehydrate loop under sustained starvation).
              try do
                if granted_via_holds_cap?(ctx, needed) do
                  :telemetry.execute([:ezagent, :authz, :granted], %{}, meta)
                  {:ok, nil}
                else
                  :telemetry.execute([:ezagent, :authz, :denied], %{}, meta)
                  {:error, :unauthorized}
                end
              rescue
                e in Ezagent.Kind.IdentityReadError ->
                  :telemetry.execute(
                    [:ezagent, :authz, :identity_read_unavailable],
                    %{},
                    Map.put(meta, :reason, e.reason)
                  )

                  {:error, :identity_read_unavailable}
              end
          end
      end
    end
  end

  # Compute the runtime cap shape from the Behavior's declared
  # `required_caps/0`. The declared cap typically has `instance: :any`
  # + `workspace_uri: :any` (the common shape for a Behavior author);
  # at dispatch time we substitute the actual target URI + target
  # workspace so the check fires against THIS dispatch.
  defp resolve_required_cap(kind_module, behavior_module, action, %URI{} = target) do
    cond do
      not function_exported?(behavior_module, :required_caps, 0) ->
        # Behavior hasn't implemented required_caps/0 yet (e.g. test
        # support modules without the callback). Fall back to the
        # legacy `cap_for_action/3` shape so the dispatch path still
        # authorizes via `ctx.caps`. Production code paths trigger the
        # invariant test (`BehaviorRequiredCapsParityTest`) so this
        # fallback is dead for production Behaviors.
        legacy_cap_map(kind_module, action, target)

      true ->
        try do
          required = behavior_module.required_caps()

          case Map.get(required, action) do
            %Ezagent.Capability{} = declared ->
              # Substitute runtime instance + workspace_uri when the
              # declaration is `:any` (the common case for a Behavior
              # author declaring "this action on any target").
              instance =
                case declared.instance do
                  :any -> Ezagent.URI.instance(target)
                  other -> other
                end

              workspace_uri =
                case declared.workspace_uri do
                  :any -> Ezagent.Capability.workspace_of(target)
                  other -> other
                end

              # When the declared kind axis is `:any` (multi-Kind
              # Behavior — e.g. Chat / Routing / Identity /
              # Template), substitute the actual target Kind's
              # type_name/0 so the check matches a cap held against
              # the concrete Kind. SPEC §7 check 11(b).
              kind_axis =
                case declared.kind do
                  :any -> safe_type_name(kind_module)
                  other -> other
                end

              %{
                kind: kind_axis,
                behavior: declared.behavior,
                # SPEC 2026-05-27 capability-action-axis — the needed-cap
                # carries the concrete action being dispatched, not the
                # declared cap's action axis (which may be `:any` for
                # orchestrator-style Behaviors). The matcher applies
                # `action_of(held_cap) == action OR :any` per §3.3.
                action: action,
                instance: instance,
                workspace_uri: workspace_uri
              }

            nil ->
              # required_caps/0 exists but doesn't declare this action.
              # Fall back to legacy shape — a Behavior that exports
              # actions/0 with action X but no required_caps[X] is a
              # bug; the invariant test catches it.
              legacy_cap_map(kind_module, action, target)
          end
        rescue
          _ -> legacy_cap_map(kind_module, action, target)
        catch
          _, _ -> legacy_cap_map(kind_module, action, target)
        end
    end
  end

  defp legacy_cap_map(kind_module, action, %URI{} = target) when is_atom(kind_module) do
    try do
      Ezagent.Capability.cap_for_action(kind_module, action, target)
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp legacy_cap_map(_, _, _), do: nil

  defp safe_type_name(kind_module) when is_atom(kind_module) do
    if function_exported?(kind_module, :type_name, 0) do
      kind_module.type_name()
    else
      :any
    end
  end

  defp safe_type_name(_), do: :any

  defp granted_via_holds_cap?(ctx, needed_map) do
    caller = Map.get(ctx, :caller)
    needed_struct = needed_map_to_struct(needed_map)

    caller_kind = resolve_caller_kind(caller)

    cond do
      is_nil(needed_struct) ->
        false

      is_nil(caller_kind) ->
        # Unknown caller Kind — use the default impl directly. Covers
        # `:vm_internal` callers (default_holds_cap?(:vm_internal, _) → true) and
        # nil callers (→ false).
        Ezagent.Kind.default_holds_cap?(caller, needed_struct)

      true ->
        Ezagent.Kind.holds_cap?(caller_kind, caller, needed_struct)
    end
  end

  # Returns `{:ok, cap}` with the FIRST `ctx.caps` capability that authorizes
  # `needed_map`, else `:error`. (Was a bare boolean; now surfaces WHICH cap
  # matched to attribute a Receipt. Allow/deny decision unchanged.)
  defp granted_via_ctx_caps?(ctx, needed_map) do
    caps = Map.get(ctx, :caps, MapSet.new())

    cond do
      caps == nil ->
        :error

      is_struct(caps, MapSet) ->
        find_authorizing_cap(caps, needed_map)

      is_list(caps) ->
        find_authorizing_cap(caps, needed_map)

      true ->
        :error
    end
  end

  defp find_authorizing_cap(caps, needed_map) do
    Enum.find_value(caps, :error, fn cap ->
      case authorizes?(cap, needed_map) do
        {:ok, _} = ok -> ok
        :error -> false
      end
    end)
  end

  # #154 predicate A: an authorizing cap counts only if it traces to a real
  # entity (`Capability.granted_by_entity?/1`) AND `matches?/2` the needed cap.
  # Returns `{:ok, cap}` on a match (to attribute a Receipt), else `:error` —
  # `granted_by_entity?/1` still fences every match (unchanged from the boolean).
  defp authorizes?(%Ezagent.Capability{} = cap, needed_map) do
    matched? =
      Ezagent.Capability.granted_by_entity?(cap) and
        try do
          Ezagent.Capability.matches?(cap, needed_map)
        rescue
          _ -> false
        catch
          _, _ -> false
        end

    if matched?, do: {:ok, cap}, else: :error
  end

  defp authorizes?(_, _), do: :error

  defp needed_map_to_struct(
         %{
           kind: k,
           behavior: b,
           instance: i,
           workspace_uri: w
         } = m
       ) do
    %Ezagent.Capability{
      kind: k,
      behavior: b,
      # SPEC 2026-05-27 capability-action-axis — propagate the concrete
      # action when present (post-SPEC needed-cap shape); fall back to
      # `:any` for any legacy caller still constructing the 4-field map.
      action: Map.get(m, :action, :any),
      instance: i,
      workspace_uri: w,
      granted_by: :plugin_declared,
      granted_at: :compile_time
    }
  end

  defp needed_map_to_struct(_), do: nil

  # Derive the caller's Kind module from the caller URI scheme.
  # Returns `nil` when the caller is not a per-Kind URI (e.g. `:vm_internal`
  # atom, nil, or a `system://` URI principal whose Kind module is not
  # loaded in this build).
  #
  # NOTE: `Ezagent.Entity.User` / `Ezagent.Entity.Agent` live in
  # `ezagent_domain_identity` / `ezagent_domain_session` — outside core's
  # dependency cone (P9). Resolve via `Code.ensure_loaded?/1` at
  # runtime, falling back to nil (default impl) when domain apps
  # haven't loaded.
  defp resolve_caller_kind(%URI{scheme: "entity"} = uri) do
    cond do
      Ezagent.URI.type?(uri, :user) -> safe_module(Ezagent.Entity.User)
      Ezagent.URI.type?(uri, :agent) -> safe_module(Ezagent.Entity.Agent)
      true -> nil
    end
  end

  defp resolve_caller_kind(%URI{scheme: "system"}) do
    # `system://` principals are spawned as User Kinds (see
    # SystemPrincipal.ensure/1) — use the User Kind module for the
    # holds_cap? resolution.
    safe_module(Ezagent.Entity.User)
  end

  defp resolve_caller_kind(_), do: nil

  defp safe_module(module) do
    if Code.ensure_loaded?(module), do: module, else: nil
  end

  # Phase 9 PR-4 (SPEC v3 §5) step 5.6 — workspace isolation.
  #
  # Caller's workspace must equal target's workspace, OR caller must
  # hold a cross-workspace cap (`workspace_uri: :any`). Bypass
  # conditions:
  #
  # - Caller is `:vm_internal` (no entity URI — internal paths like
  #   Workspace.create dispatch_mutation use `:vm_internal` as caller).
  #   Returning :ok here matches the existing CapBAC-bypass posture
  #   for `:vm_internal` callers — they're trusted in-VM code.
  # - Target's workspace is `:any` (cross-cutting schemes like
  #   `system://routing/default`, `template://`, `resource://` — these
  #   are not workspace-scoped by design).
  # - Caller and target share a workspace (the common intra-workspace
  #   case — every PR-3-and-prior test path).
  # - Caller's caps include at least one cross-workspace cap. NOTE:
  #   the authz step (5.5) has already passed — the cross-workspace
  #   cap is the one that authorized the action. We re-scan the caps
  #   here because we only need to know "does ANY cap have
  #   workspace_uri: :any" — a cheap MapSet enum.
  #
  # Returns `:ok` on bypass / match, `{:error, :cross_workspace_denied}`
  # otherwise. The atom is distinct from `:unauthorized` (invariant 9
  # — inbound transports must surface this with a different message +
  # reaction so users see why dispatch failed).
  defp workspace_isolation_check(behavior_module, target, ctx) do
    # PR-CC-2-v2 SPEC §2b — `workspace_scoped?/0` lets a Behavior opt
    # out of workspace isolation (default: `true`). When `false`, the
    # check is a no-op (e.g. Lifecycle admin termination, pure-data
    # read actions whose target is workspace-agnostic).
    if Ezagent.ActionSet.workspace_scoped?(behavior_module) do
      do_workspace_isolation_check(target, ctx)
    else
      :ok
    end
  end

  defp do_workspace_isolation_check(target, ctx) do
    caller_ws = workspace_of_caller(Map.get(ctx, :caller))
    target_ws = Ezagent.Capability.workspace_of(target)

    meta = %{
      target: target,
      caller: Map.get(ctx, :caller),
      caller_workspace: caller_ws,
      target_workspace: target_ws
    }

    cond do
      caller_ws == :any ->
        :ok

      target_ws == :any ->
        :ok

      ws_equal?(caller_ws, target_ws) ->
        :ok

      caps_have_cross_workspace?(ctx) ->
        :ok

      true ->
        :telemetry.execute([:ezagent, :workspace, :denied], %{}, meta)
        {:error, :cross_workspace_denied}
    end
  end

  # Caller workspace derivation:
  #
  # - `:vm_internal` (atom) → `:any` (bypass — trusted in-VM path)
  # - `entity://<type>/<workspace>/<name>` → workspace URI
  # - `session://<template>/<name>` → WorkspaceRegistry lookup
  # - `workspace://<name>` → the URI itself
  # - `:vm_internal` (trusted in-VM caller) → `:any`
  # - nil or unknown → `:any` (degraded; the authz step would have
  #   denied without a real principal)
  defp workspace_of_caller(:vm_internal), do: :any
  defp workspace_of_caller(nil), do: :any

  defp workspace_of_caller(%URI{} = uri) do
    try do
      Ezagent.Capability.workspace_of(uri)
    rescue
      _ -> :any
    end
  end

  defp workspace_of_caller(_), do: :any

  defp ws_equal?(:any, _), do: true
  defp ws_equal?(_, :any), do: true

  defp ws_equal?(%URI{} = a, %URI{} = b),
    do: URI.to_string(a) == URI.to_string(b)

  defp ws_equal?(_, _), do: false

  # Phase 9 PR-8 (SPEC v3 §13.3) — the arity-2 form honors the
  # membership-based bypass: ANY cap held by a `workspace://system`
  # member counts as cross-workspace (Keycloak realm-admin model).
  # The `:vm_internal` caller short-circuit above already returns :ok for
  # internal-only flows, so the predicate here only fires for real
  # entity URIs.
  defp caps_have_cross_workspace?(ctx) do
    caps = Map.get(ctx, :caps, MapSet.new())
    caller = Map.get(ctx, :caller)
    Enum.any?(caps, &Ezagent.Capability.cross_workspace?(&1, caller))
  end

  defp validate_args(behavior_module, action, args) do
    interface = behavior_module.interface()

    case Map.fetch(interface, action) do
      {:ok, %{args: schema}} ->
        Ezagent.InterfaceValidator.validate(args, schema)

      {:ok, _action_def} ->
        # Action declared but no args schema — accept anything.
        :ok

      :error ->
        {:error, {:unknown_action, action}}
    end
  end

  # Phase 1.5 (SPEC 2026-05-28 Router/Behavior/Kind) — branch between
  # the legacy `invoke/4` contract and the new per-action declarative
  # contract (`handle_<action>/2` + `apply_effects/2`).
  #
  # New-contract Behaviors carry a `__behavior__?/0` marker injected by
  # `use Ezagent.ActionSet`. The runtime resolves the action's handler
  # atom (`:handle_<action>`), invokes it with `(args, ctx)` (slice
  # exposed to the handler via `ctx[:read]/1-2`), applies the returned
  # effects against the slice, and lifts the result back into the
  # `{:ok, new_slice, result}` shape so the rest of the dispatch
  # pipeline (snapshot commit, slice-change emit, telemetry) is
  # unchanged.
  #
  # Phase 3 deletion (2026-05-28) removed the legacy `invoke/4`
  # fallback — every Behavior the runtime sees MUST be new-style
  # (`__behavior__?/0` returns true). A non-conforming module raises
  # at dispatch time via the `{:error, {:not_a_behavior, ...}}` guard
  # in `invoke_behavior/5`.
  defp invoke_behavior(behavior_module, action, slice, args, ctx) do
    if Ezagent.ActionSet.new_style?(behavior_module) do
      invoke_new_contract(behavior_module, action, slice, args, ctx)
    else
      Logger.error(
        "Behavior #{inspect(behavior_module)} is not a new-style Behavior " <>
          "(missing `use Ezagent.ActionSet` / `__behavior__?/0`). Dispatch refused."
      )

      {:error, {:not_a_behavior, behavior_module}}
    end
  end

  # New-contract dispatch (SPEC §4.3 / §4.4).
  #
  # Flow:
  # 1. Validate the action is declared via `__actions__/0`. The
  #    BehaviorRegistry already filtered by `{kind_module, action}`
  #    BEFORE this call, but a new-contract Behavior may have been
  #    cap-registered while declaring its action set independently;
  #    re-check here gives a precise `:unknown_action` error instead
  #    of a `FunctionClauseError` from a missing handler/2.
  # 2. Resolve the handler atom — must already exist (`@before_compile`
  #    enforces `def handle_<action>/2` per action declaration).
  # 3. Call `handle_<action>(args, ctx_with_read)` where `ctx[:read]`
  #    exposes the current slice's fields to the handler (the new
  #    contract doesn't receive the slice as an arg).
  # 4. Apply the handler's effects against `slice` (Behavior.apply_effects/2).
  # 5. Lift the result back into the 3-tuple shape the rest of
  #    `handle_dispatch/4` consumes — the framework-state from
  #    `apply_effects` IS the new slice (each `{:set, key, value}` in
  #    the handler's returned effects mutates the slice).
  #
  # Halts and bad-shape handler returns are mapped to `{:error, _}`
  # tuples that flow through the same telemetry-on-error branch as
  # the legacy path.
  defp invoke_new_contract(behavior_module, action, slice, args, ctx) do
    cond do
      action not in Ezagent.ActionSet.action_names(behavior_module) ->
        {:error, {:unknown_action, action}}

      true ->
        handler_name = handler_atom_for(action)

        if function_exported?(behavior_module, handler_name, 2) do
          invoke_new_contract_handler(behavior_module, action, handler_name, slice, args, ctx)
        else
          # `@before_compile` should prevent this — a missing handler is
          # a compile-time error in `use Ezagent.ActionSet`. Guard
          # defensively so a manually-crafted (e.g. test-time) module
          # without the macro doesn't crash the dispatcher.
          {:error, {:missing_handler, behavior_module, handler_name}}
        end
    end
  end

  defp invoke_new_contract_handler(behavior_module, action, handler_name, slice, args, ctx) do
    handler_ctx = build_handler_ctx(slice, ctx)

    # Lifecycle Phase A (SPEC §2 fine interception, F6) — wrap the handler
    # dispatch with the OPTIONAL `pre_handle/3` (before, may halt/rewrite
    # args) + `post_handle/4` (after, may rewrite result/effects) hooks.
    # Both are probed via `function_exported?/3`, so a Behavior that
    # doesn't declare them (the common case + every legacy Behavior) is
    # byte-for-byte unaffected.
    case run_pre_handle(behavior_module, action, args, handler_ctx) do
      {:halt, result} ->
        # pre_handle short-circuited — skip the handler, no effects, slice
        # unchanged. P2.5c 4th element `[]`: no effects → no deferred dispatches.
        {:ok, slice, result, []}

      {:error, _reason} = err ->
        err

      {:cont, effective_args} ->
        invoke_handler_with_post(
          behavior_module,
          action,
          handler_name,
          slice,
          effective_args,
          handler_ctx,
          ctx
        )
    end
  end

  # Run the handler, then thread its (result, effects) through
  # `post_handle/4` before executing the effects.
  defp invoke_handler_with_post(
         behavior_module,
         action,
         handler_name,
         slice,
         args,
         handler_ctx,
         ctx
       ) do
    case apply(behavior_module, handler_name, [args, handler_ctx]) do
      {:ok, result, effects} when is_list(effects) ->
        {result, effects} =
          run_post_handle(behavior_module, action, result, effects, handler_ctx)

        apply_new_contract_effects(slice, result, effects, ctx)

      {:ok, result} ->
        # No effects → run post_handle with an empty effect list so a
        # post_handle hook may still INJECT effects (audit/mirror).
        {result, effects} = run_post_handle(behavior_module, action, result, [], handler_ctx)

        # P2.5c — 4-tuple: `[]` for no-effects; else from apply_new_contract_effects/4.
        case effects do
          [] -> {:ok, slice, result, []}
          _ -> apply_new_contract_effects(slice, result, effects, ctx)
        end

      {:error, _reason} = err ->
        err

      other ->
        Logger.error(
          "Behavior #{inspect(behavior_module)}.#{handler_name}/2 returned bad shape: " <>
            "#{inspect(other)}"
        )

        {:error, {:bad_handler_return, behavior_module, action, other}}
    end
  catch
    kind, reason ->
      Logger.error(
        "Behavior #{inspect(behavior_module)}.#{handler_name}/2 crashed: " <>
          "#{inspect(kind)} #{inspect(reason)}"
      )

      {:error, {:behavior_exception, kind, reason}}
  end

  # `pre_handle/3` — OPTIONAL fine interception BEFORE the handler.
  # Returns (normalized to a uniform internal shape):
  #   :cont                → {:cont, args}   (proceed unchanged)
  #   {:cont, new_args}    → {:cont, new_args}
  #   {:halt, result}      → {:halt, result} (skip handler, no effects)
  #   {:error, reason}     → {:error, reason} (deny)
  defp run_pre_handle(behavior_module, action, args, handler_ctx) do
    if function_exported?(behavior_module, :pre_handle, 3) do
      case behavior_module.pre_handle(action, args, handler_ctx) do
        :cont -> {:cont, args}
        {:cont, new_args} when is_map(new_args) -> {:cont, new_args}
        {:halt, result} -> {:halt, result}
        {:error, reason} -> {:error, reason}
      end
    else
      {:cont, args}
    end
  end

  # `post_handle/4` — OPTIONAL fine interception AFTER the handler, BEFORE
  # effects execute. May replace the (result, effects) pair.
  #   {:ok, result, effects} → use the replacement pair
  #   :cont                  → keep (result, effects) unchanged
  defp run_post_handle(behavior_module, action, result, effects, handler_ctx) do
    if function_exported?(behavior_module, :post_handle, 4) do
      case behavior_module.post_handle(action, result, effects, handler_ctx) do
        {:ok, new_result, new_effects} when is_list(new_effects) -> {new_result, new_effects}
        :cont -> {result, effects}
      end
    else
      {result, effects}
    end
  end

  # Build the `ctx` handed to a `handle_<action>/2` handler.
  #
  # Legacy (flat) slice: `ctx[:read].(key, default)` reads the slice
  # directly — byte-identical to the pre-Lifecycle engine.
  #
  # Lifecycle Phase A (SPEC 2026-05-29 §2.2) — a two-container slice
  # (`%{state: _, transients: _}`) exposes:
  #   - `ctx.read.(key, default)` → reads from the PERSISTENT `:state`
  #     sub-map (so a handler's `ctx.read.(:conversation, [])` sees the
  #     durable field, NOT the literal `:state` / `:transients` keys).
  #   - `ctx.transients` → the volatile container (read view), so a
  #     handler reads a PID/ref/handle via `ctx.transients[:monitors]`.
  # The `:set` / `:set_transient` effects the handler returns are routed
  # to the matching sub-map by `Ezagent.ActionSet.apply_effects/2`.
  defp build_handler_ctx(%{state: st, transients: tr} = _slice, ctx)
       when is_map(st) and is_map(tr) do
    ctx
    |> Map.put(:read, fn key, default -> Map.get(st, key, default) end)
    |> Map.put(:state, st)
    |> Map.put(:transients, tr)
  end

  defp build_handler_ctx(flat_slice, ctx) when is_map(flat_slice) do
    Map.put(ctx, :read, fn key, default -> Map.get(flat_slice, key, default) end)
  end

  @spec apply_signal_effects(
          %{state: map(), transients: map()},
          [Ezagent.ActionSet.effect()],
          map()
        ) ::
          {:ok, %{state: map(), transients: map()}} | :ignore
  defdelegate apply_signal_effects(slice, effects, ctx), to: Ezagent.Kind.Runtime.Effects

  defp apply_new_contract_effects(slice, result, effects, ctx) do
    Ezagent.Kind.Runtime.Effects.apply_new_contract_effects(slice, result, effects, ctx)
  end

  defp handler_atom_for(action) when is_atom(action) do
    # Use `to_existing_atom/1` — `use Ezagent.ActionSet` already
    # compiled the `:handle_<action>` atom into the BEAM via the
    # `def handle_<action>` clause `@before_compile` enforced. A
    # genuinely missing handler is the `function_exported?/3` guard
    # in `invoke_new_contract/5`, not an atom-table lookup.
    String.to_existing_atom("handle_" <> Atom.to_string(action))
  rescue
    ArgumentError ->
      # Pathological — the action atom is declared but no `handle_<x>`
      # symbol ever existed in the BEAM. Surface as a clear error
      # rather than crashing the caller's `case`.
      :__no_handler_atom__
  end

  defp maybe_inject_sibling_slices(ctx, behavior_module, state) do
    Ezagent.Kind.Runtime.Context.maybe_inject_sibling_slices(ctx, behavior_module, state)
  end

  defp derive_session_uri(target), do: Ezagent.Kind.Runtime.Context.derive_session_uri(target)
end
