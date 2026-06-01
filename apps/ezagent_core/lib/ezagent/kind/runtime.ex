defmodule Ezagent.Kind.Runtime do
  @moduledoc """
  In-process dispatch flow inside a Kind GenServer.

  ## New-contract effect execution order (Phase 1.5b)

  When the dispatched Behavior is new-style (`use Ezagent.Behavior`),
  the handler's `{:ok, result, effects}` return runs through
  `Ezagent.Behavior.apply_effects/2` and then THIS module executes
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

  The handler return + effect grammar live in `Ezagent.Behavior` —
  this module is the EXECUTOR; the SCHEMA is over there.

  ## Original dispatch flow

  Runs Appendix A steps 5-10 once the invocation has been routed to a
  specific pid by `Ezagent.Invocation.dispatch/1`:

  - **5**: `BehaviorRegistry.lookup({kind_module, action})`
  - **5.5**: authz gate — `Ezagent.Capability.matches?` against ctx.caps
    (Phase 3d hard flip per P3-D6). Emits `[:ezagent, :authz, :granted]`
    or `[:ezagent, :authz, :denied]`. The Phase 1-2 permissive stub
    (emit `:stub_grant` + always grant) is GONE; check_invariants #9
    enforces the atom no longer appears in code.
  - **5.6**: workspace isolation — caller and target must share a
    workspace, OR caller must hold a cross-workspace cap
    (`workspace_uri: :any`). Phase 9 PR-4 (SPEC v3 §5). Bypass
    conditions: caller is `:system` (no entity URI), target is a
    cross-cutting scheme (`system://`, `template://`, `resource://`
    — workspace_of returns `:any`), or caller already holds a
    cross-workspace cap. Returns `{:error, :cross_workspace_denied}`
    on isolation violation — distinct from `:unauthorized` per
    invariant 9, so inbound transports can surface a different
    failure message + reaction emoji.
  - **5.7**: validate args against `behavior.interface()[action].args`
  - **6**: extract slice = `state[behavior.state_slice()]`
  - **7**: `behavior.invoke(action, slice, args, ctx)`
  - **8**: shape return into `{:ok, new_slice}` or `{:ok, new_slice, result}`
  - **9**: `put_in(state, [slice_key], new_slice)` (snapshot is Phase 3)
  - **10**: emit `[:ezagent, :invoke, :stop]` telemetry

  Per DECISIONS P1-D2's trade-off note: this function must be
  **defensive** about state shape because the shared `Ezagent.Kind.Server`
  hosts multiple Kind types whose slices may differ in shape. Phase 1
  only has Echo (map slice) so this is mostly theoretical for now —
  but the function deliberately uses `Map.get` rather than struct
  field access for forward-compat.
  """

  require Logger

  @type slice_state :: %{atom() => map()}
  # PR-N1 round-2 MEDIUM: success branches now carry a 4th element —
  # the optional `slice_change_event` for `Kind.Server` to fire
  # AFTER `Snapshot.maybe_save/4`. Was a 2-tuple `{:ok, state}` and
  # 3-tuple `{:ok, state, result}`. Backwards-compatible: legacy
  # callers that only matched the success atom + state still work
  # because the new shape extends, not replaces.
  @type result ::
          {:ok, slice_state(), term(), slice_change_event() | nil}
          | {:ok, slice_state(), nil, slice_change_event() | nil}
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

    # Phase 2: Behaviors that span multiple Kinds (e.g. Chat: Session does
    # send/join/leave, User/Agent do receive) need to branch on which Kind
    # they're currently hosting + know that Kind instance's URI for fan-out.
    # Inject both into ctx at this single point so plugins never have to
    # plumb it themselves.
    #
    # Phase 7 PR 43 (D7-3): also inject `:session_uri` derived from the
    # target URI. This is what `Ezagent.Capability.instance_match?/2`
    # consumes when evaluating a `{:within_session, S}` scope-tuple
    # cap shape (Decision #137). Without this enrichment, CapBAC has
    # no way to know which session a dispatch is happening in, so
    # scope-bounded delegation can't be enforced. Derivation is pure
    # URI parsing — no dispatch, no registry lookup, O(1).
    # PR-N3 r4 (Allen 2026-05-25) — pre-allocate the `SliceChange`
    # broadcast cursor BEFORE invoke so the Behavior can write
    # cursor-keyed entries into its slice that match what subscribers
    # will receive in the envelope. Allocation here means every
    # dispatch (even read-only Behaviors that don't mutate the slice)
    # burns a cursor number; the moduledoc on
    # `Ezagent.SliceChange.Cursors` documents skipping is acceptable
    # (cursors are a "low-cost ordering hint", not a tight log
    # primary key). The alternative — allocating AFTER invoke — would
    # force the Behavior to write cursor-less ring entries and then
    # have Runtime back-patch them, which violates the "Behavior owns
    # invoke contract" boundary and is more code for the same
    # outcome. Pre-allocation keeps the Behavior the SoT for its own
    # slice.
    #
    # `SliceChange.emit/1` reads the pre-allocated cursor from the
    # producer event (instead of calling `Cursors.next/1` itself —
    # see `Ezagent.SliceChange.build_broadcast_event/2`) so the
    # envelope's `:cursor` matches the slice's ring entry exactly.
    slice_change_cursor = Ezagent.SliceChange.Cursors.next(self_uri)

    enriched_ctx =
      ctx
      |> Map.put(:kind_module, kind_module)
      |> Map.put(:self_uri, self_uri)
      |> Map.put(:session_uri, derive_session_uri(target))
      |> Map.put(:slice_change_cursor, slice_change_cursor)

    with {:ok, {behavior_name_atom, action}} <- Ezagent.URI.behavior_action(target),
         {:ok, behavior_module} <- lookup_behavior(kind_module, action),
         :ok <- authz_check(kind_module, behavior_module, action, target, enriched_ctx),
         :ok <- workspace_isolation_check(behavior_module, target, enriched_ctx),
         :ok <- validate_args(behavior_module, action, args),
         slice_key <- behavior_module.state_slice(),
         slice <- Map.get(state, slice_key, %{}),
         # Allen 2026-05-26 (codex CRIT-1 closure) — scope the sibling
         # slice exposure to ONLY what the Behavior declared via
         # `reads_sibling_slices/0`. Default `[]` → no `:sibling_slices`
         # key in ctx; the wide `:all_slices` injection that codex
         # flagged as a generic secret-read escape hatch is gone. A
         # Behavior that legitimately needs to read a sibling slice
         # (e.g. CurlAgent reading `:api_keys` to fetch its outbound
         # credential, deadlock-free) declares it explicitly.
         invoke_ctx <- maybe_inject_sibling_slices(enriched_ctx, behavior_module, state),
         {:ok, new_slice, result_or_nil} <-
           invoke_behavior(behavior_module, action, slice, args, invoke_ctx) do
      # Step 9 — put_in state. Snapshot wiring is Phase 1 step 3.
      new_state = Map.put(state, slice_key, new_slice)

      # Step 9.5 (SPEC v2 PR-N1, Allen 2026-05-24) — slice-change
      # event preparation. Notification v2: slice mutation IS the
      # notification trigger.
      #
      # Codex PR-N1 round-2 MEDIUM fix: we no longer EMIT from here.
      # Emit happens in `Kind.Server` AFTER `Snapshot.maybe_save/4`
      # so a PubSub outage can never roll back a durably-persisted
      # mutation. The event payload is computed here (we have the
      # slice diff + action context), then returned in the result
      # envelope for `Kind.Server` to fire post-commit.
      #
      # Codex PR-N1 round-1 HIGH-2 fix: bare INSTANCE URI for both
      # topic + payload self_uri — `target` includes `?action=…`
      # query but subscribers want one topic per Kind instance.
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

      # 3-tuple result shape carries an optional `slice_change_event`
      # for `Kind.Server` to fire after snapshot persistence. `nil`
      # means no slice mutation happened (Behavior was read-only or
      # the new slice equalled the old). Codex PR-N1 round-2 MEDIUM.
      case result_or_nil do
        nil -> {:ok, new_state, nil, slice_change_event}
        result -> {:ok, new_state, result, slice_change_event}
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

  defp lookup_behavior(kind_module, action) do
    case Ezagent.BehaviorRegistry.lookup(kind_module, action) do
      {:ok, behavior_module} -> {:ok, behavior_module}
      :error -> {:error, {:unknown_action, action}}
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
  # Backward-compat: `ctx.caps` plumbing is preserved (PR-CC-2c deletes
  # the field). When `ctx.caps` is populated AND contains a matching
  # cap, that's an acceptable grant too — used by tests + bootstrap
  # paths that pre-date the slice-backed flow. The dual check is a
  # short-lived bridge; PR-CC-2c removes the ctx.caps branch.
  defp authz_check(kind_module, behavior_module, action, target, ctx) do
    cap_exempt? = action in Ezagent.Behavior.cap_exempt_actions_of(behavior_module)

    if cap_exempt? do
      :telemetry.execute([:ezagent, :authz, :exempt], %{}, %{
        kind_module: kind_module,
        action: action,
        target: target,
        caller: Map.get(ctx, :caller)
      })

      :ok
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
        is_nil(needed) ->
          :telemetry.execute([:ezagent, :authz, :denied], %{}, meta)
          {:error, :unauthorized}

        # 2026-05-26 (Allen perf bug): reorder ctx.caps check BEFORE the
        # holds_cap? slice lookup. The slice path issues a
        # `GenServer.call(caller_kind_pid, ...)` to read the caller's
        # `:identity` slice. For non-user/non-agent callers (e.g.
        # `entity://worker/system/em_*`, system workers, plugin pseudo-
        # entities) `resolve_caller_kind/1` returns nil so the call
        # falls through to `default_holds_cap?/2` which STILL calls
        # `Kind.get_slice(caller_uri, :identity)` — and when the caller
        # IS the dispatching process (worker dispatching its own
        # subscribe_from), that GenServer.call deadlocks against
        # itself until the 5s default timeout fires.
        #
        # Workers carry their compile-time caps via `ctx.caps` (the
        # `system://worker-publish` system principal — see Catalog).
        # Checking ctx.caps first means workers (and any other
        # ctx.caps-bearing caller) never trigger the self-call deadlock,
        # AND the cheap path runs first for everyone. Slice-resolved
        # caps still work — they're just the second-line check, used
        # by ordinary user/agent dispatches whose identity slice IS
        # the source of truth.
        granted_via_ctx_caps?(ctx, needed) ->
          :telemetry.execute([:ezagent, :authz, :granted], %{}, meta)
          :ok

        granted_via_holds_cap?(ctx, needed) ->
          :telemetry.execute([:ezagent, :authz, :granted], %{}, meta)
          :ok

        true ->
          :telemetry.execute([:ezagent, :authz, :denied], %{}, meta)
          {:error, :unauthorized}
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
              # Behavior — e.g. Chat / Routing / Presence / Identity /
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
        # `:system` callers (default_holds_cap?(:system, _) → true) and
        # nil callers (→ false).
        Ezagent.Kind.default_holds_cap?(caller, needed_struct)

      true ->
        Ezagent.Kind.holds_cap?(caller_kind, caller, needed_struct)
    end
  end

  defp granted_via_ctx_caps?(ctx, needed_map) do
    caps = Map.get(ctx, :caps, MapSet.new())

    cond do
      caps == nil ->
        false

      is_struct(caps, MapSet) ->
        Enum.any?(caps, fn cap ->
          try do
            Ezagent.Capability.matches?(cap, needed_map)
          rescue
            _ -> false
          catch
            _, _ -> false
          end
        end)

      is_list(caps) ->
        Enum.any?(caps, fn cap ->
          try do
            Ezagent.Capability.matches?(cap, needed_map)
          rescue
            _ -> false
          catch
            _, _ -> false
          end
        end)

      true ->
        false
    end
  end

  defp needed_map_to_struct(%{
         kind: k,
         behavior: b,
         instance: i,
         workspace_uri: w
       } = m) do
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
  # Returns `nil` when the caller is not a per-Kind URI (e.g. `:system`
  # atom, nil, or a `system://` URI principal whose Kind module is not
  # loaded in this build).
  #
  # NOTE: `Ezagent.Entity.User` / `Ezagent.Entity.Agent` live in
  # `ezagent_domain_identity` / `ezagent_domain_chat` — outside core's
  # dependency cone (P9). Resolve via `Code.ensure_loaded?/1` at
  # runtime, falling back to nil (default impl) when domain apps
  # haven't loaded.
  defp resolve_caller_kind(%URI{scheme: "entity", host: "user"}) do
    safe_module(Ezagent.Entity.User)
  end

  defp resolve_caller_kind(%URI{scheme: "entity", host: "agent"}) do
    safe_module(Ezagent.Entity.Agent)
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
  # - Caller is `:system` (no entity URI — bootstrap / internal paths
  #   like Workspace.create dispatch_mutation use `:system` as caller).
  #   Returning :ok here matches the existing CapBAC-bypass posture
  #   for `:system` callers historically — they're trusted.
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
    if Ezagent.Behavior.workspace_scoped?(behavior_module) do
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
  # - `:system` (atom) → `:any` (bypass — bootstrap path)
  # - `entity://<type>/<workspace>/<name>` → workspace URI
  # - `session://<template>/<name>` → WorkspaceRegistry lookup
  # - `workspace://<name>` → the URI itself
  # - `system://...` callers → `:any`
  # - nil or unknown → `:any` (degraded; the authz step would have
  #   denied without a real principal)
  defp workspace_of_caller(:system), do: :any
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
  # The `:system` caller short-circuit above already returns :ok for
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
  # `use Ezagent.Behavior`. The runtime resolves the action's handler
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
    if Ezagent.Behavior.new_style?(behavior_module) do
      invoke_new_contract(behavior_module, action, slice, args, ctx)
    else
      Logger.error(
        "Behavior #{inspect(behavior_module)} is not a new-style Behavior " <>
          "(missing `use Ezagent.Behavior` / `__behavior__?/0`). Dispatch refused."
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
      action not in Ezagent.Behavior.action_names(behavior_module) ->
        {:error, {:unknown_action, action}}

      true ->
        handler_name = handler_atom_for(action)

        if function_exported?(behavior_module, handler_name, 2) do
          invoke_new_contract_handler(behavior_module, action, handler_name, slice, args, ctx)
        else
          # `@before_compile` should prevent this — a missing handler is
          # a compile-time error in `use Ezagent.Behavior`. Guard
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
        # unchanged. (A pre_handle authz gate returning {:halt, result}.)
        {:ok, slice, result}

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

        case effects do
          [] -> {:ok, slice, result}
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
  # to the matching sub-map by `Ezagent.Behavior.apply_effects/2`.
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

  @doc """
  Lifecycle signal effect application (T1 — Phase B foundation).

  Runs the SAME full effect pipeline as the action path
  (`apply_new_contract_effects/4`) for a `handle_signal/2` effect list:
  `Ezagent.Behavior.apply_effects/2` (state + transient reduced pre-commit,
  R10-2 atomicity) → `execute_buckets/2` (Saga → DispatchesReturning →
  Dispatches → Notifies → Events → Terminations, identical order).

  Used by `Ezagent.Lifecycle.__run_signal__/4` so a real signal handler
  (e.g. `ExternalMirror`'s `:publisher_event` / `:ezagent_em_reconcile`,
  `Chat`'s `:DOWN`) can DISPATCH / EMIT / NOTIFY declaratively instead of
  imperatively — the Phase C "no imperative `Invocation.dispatch` in dev
  code" gate.

  Return contract (mapped to the engine's `handle_kind_message/3` shape,
  which only carries a new slice — NOT a `{slice, result}` pair):

  - `{:ok, new_slice}` — effects applied + side-effect buckets executed;
    `new_slice` is the reduced two-container slice the caller commits.
  - `:ignore` — either a `{:halt, _}` short-circuit (roll back: NO slice
    change, side-effect buckets DROPPED — same atomicity as the action
    path) OR a side-effect bucket failure (a `:dispatch`/`:saga` returned
    `{:error, _}`). In both cases the slice is NOT advanced, mirroring the
    action path's "atomic unit — partial side effects don't leak."

  `ctx` MUST carry `:self_uri` (for EventLog aggregate + dispatch caller
  default); `:caller` / `:trace_id` are optional (same as the action
  path).
  """
  @spec apply_signal_effects(
          %{state: map(), transients: map()},
          [Ezagent.Behavior.effect()],
          map()
        ) :: {:ok, %{state: map(), transients: map()}} | :ignore
  def apply_signal_effects(slice, effects, ctx) when is_list(effects) do
    case Ezagent.Behavior.apply_effects(effects, slice) do
      {:ok, buckets} ->
        case execute_buckets(buckets, ctx) do
          :ok ->
            {:ok, buckets.state}

          {:error, reason} ->
            Logger.warning(
              "Ezagent.Kind.Runtime.apply_signal_effects: side-effect bucket failed; " <>
                "slice NOT advanced (atomic signal): reason=#{inspect(reason)}"
            )

            :ignore
        end

      {:halt, reason, _partial} ->
        Logger.debug(
          "Ezagent.Kind.Runtime.apply_signal_effects: signal halted; " <>
            "slice NOT advanced: reason=#{inspect(reason)}"
        )

        :ignore
    end
  end

  # Phase 1.5b — execute the full effect grammar produced by
  # `Ezagent.Behavior.apply_effects/2`.
  #
  # Execution order: State → Halt-check → Saga → Dispatches → Notifies
  # → Events → Terminations. See the moduledoc + SPEC §4.4 for the
  # rationale.
  #
  # `apply_effects/2` already mutated the slice (`:set` effects ran
  # eagerly into its accumulator); the buckets we execute here are
  # the OUT-OF-SLICE side effects.
  #
  # `ctx` carries `:caller`, `:self_uri`, `:slice_change_cursor`, etc.
  # We use it to derive `workspace_uri` (for EventLog), `caller` (for
  # both EventLog and re-dispatched Cmds), and the aggregate URI for
  # events (the dispatching Kind's `:self_uri`).
  defp apply_new_contract_effects(slice, result, effects, ctx) do
    case Ezagent.Behavior.apply_effects(effects, slice) do
      {:ok, buckets} ->
        case execute_buckets(buckets, ctx) do
          :ok ->
            {:ok, buckets.state, result}

          {:error, _} = err ->
            err
        end

      {:halt, reason, _partial} ->
        # `apply_effects/2` is the single point that knows whether to
        # commit partial effects — its `:halt` return is the signal
        # to roll back. Propagate as a typed error so the caller sees
        # the dispatch failed without persisting anything. Side-effect
        # buckets collected prior to the halt are DROPPED — the Kind
        # has already not-yet-committed the slice and the dispatch is
        # an atomic unit; partial side effects would leak observability
        # about a failed transaction.
        {:error, {:halt, reason}}
    end
  end

  # Bucket execution — runs Saga → DispatchesReturning → Dispatches →
  # Notifies → Events → Terminations in that order. First failing
  # dispatch / saga / dispatch_returning short-circuits with
  # `{:error, _}`. Notifies / events / terminations NEVER abort the
  # dispatch (broadcasts/audit/termination are observational +
  # idempotent; their failure is logged but the dispatch still
  # completes from the caller's POV — the slice WILL be committed
  # and the slice_change event WILL fire).
  #
  # 2026-05-29 dispatch_returning SPEC §5 — `:dispatch_returning`
  # runs IMMEDIATELY AFTER saga + BEFORE regular `:dispatch` so the
  # `returning` map is populated before any downstream effect that
  # might reference a `{:ref, name, path}` from a returning
  # dispatch. We THEN re-substitute refs against the freshly-
  # bound names in the remaining buckets (dispatches/notifies/
  # events) — `apply_effects/2`'s earlier substitution only saw
  # `:effect_returning` bindings; this second pass covers
  # `:dispatch_returning` bindings.
  defp execute_buckets(buckets, ctx) do
    with :ok <- execute_saga(buckets.saga, ctx),
         {:ok, returning2} <-
           execute_dispatches_returning(
             Map.get(buckets, :dispatches_returning, []),
             buckets.returning,
             ctx
           ) do
      # Re-substitute refs in the buckets that haven't run yet, using
      # the FULL returning map (effect_returning + dispatch_returning
      # bindings). `apply_effects/2`'s first pass already substituted
      # the `:effect_returning` portion; this pass covers the new
      # `:dispatch_returning` bindings without losing the earlier ones
      # (same module, same predicate — idempotent on already-
      # substituted leaves).
      dispatches = Enum.map(buckets.dispatches, &Ezagent.Behavior.substitute_refs(&1, returning2))
      notifies = Enum.map(buckets.notifies, &Ezagent.Behavior.substitute_refs(&1, returning2))
      events = Enum.map(buckets.events, &Ezagent.Behavior.substitute_refs(&1, returning2))

      with :ok <- execute_dispatches(dispatches, ctx) do
        execute_notifies(notifies)
        execute_events(events, ctx)
        execute_terminations(buckets.terminations, ctx)
        :ok
      end
    end
  end

  # 2026-05-29 dispatch_returning SPEC §4-6 — synchronously run each
  # `:dispatch_returning` effect through `Router.dispatch/1`, binding
  # successes into the `returning` accumulator. Any failure short-
  # circuits with `{:error, {:dispatch_returning_failed, name, reason}}`
  # — the handler asked for the dispatch's value to make a downstream
  # decision; if the dispatch failed, the safe semantics is abort.
  #
  # Cmds may reference earlier `:effect_returning`/`:dispatch_returning`
  # bindings via `{:ref, ...}`. We substitute against `returning_acc`
  # BEFORE handing the Cmd to the Router so the dispatch sees concrete
  # values.
  #
  # Caller / trace_id enrichment mirrors `enrich_dispatch_cmd/2` (the
  # regular `:dispatch` path) so a handler-supplied Cmd without an
  # explicit caller inherits `self_uri` — same hygiene as `:dispatch`.
  defp execute_dispatches_returning([], returning, _ctx), do: {:ok, returning}

  defp execute_dispatches_returning(
         [{:dispatch_returning, %Ezagent.Cmd{} = cmd, opts} | rest],
         returning_acc,
         ctx
       ) do
    name = Keyword.fetch!(opts, :bind_as)

    # Substitute refs in the Cmd struct against bindings collected so
    # far. `substitute_refs/2` walks the struct fields, so
    # `cmd.target`, `cmd.args`, and `cmd.ctx` all get the substitution.
    resolved_cmd =
      cmd
      |> Ezagent.Behavior.substitute_refs(returning_acc)
      |> enrich_dispatch_cmd(ctx)

    case Ezagent.Router.dispatch(resolved_cmd) do
      {:ok, value} ->
        execute_dispatches_returning(rest, Map.put(returning_acc, name, value), ctx)

      :ok ->
        # Cast / fire-and-forget. Bind `:ok` so any downstream
        # `{:ref, name}` still substitutes deterministically. Authors
        # who care about the value should set `reply: {:caller_inbox, _}`
        # on the Cmd; see SPEC §4b + §11 attack vector 5.
        execute_dispatches_returning(rest, Map.put(returning_acc, name, :ok), ctx)

      {:error, reason} ->
        Logger.warning(
          "Ezagent.Kind.Runtime: :dispatch_returning failed; aborting handler: " <>
            "bind_as=#{inspect(name)} target=#{inspect(cmd.target)} " <>
            "action=#{inspect(cmd.action)} reason=#{inspect(reason)}"
        )

        {:error, {:dispatch_returning_failed, name, reason}}
    end
  end

  # `:saga` effect — `apply_effects/2` packages the saga as either
  # `nil` (no saga in this handler return) or `{:saga, %Saga{}}`.
  # We delegate to `Ezagent.SagaRunner.execute/2`; its return
  # `{:ok, _}` is success; `{:error, _}` halts subsequent effects.
  defp execute_saga(nil, _ctx), do: :ok

  defp execute_saga({:saga, saga}, ctx) do
    case Ezagent.SagaRunner.execute(saga, ctx) do
      {:ok, _saga_result} ->
        :ok

      {:error, _} = err ->
        Logger.warning(
          "Ezagent.Kind.Runtime: saga effect failed; remaining effect " <>
            "buckets aborted: #{inspect(err)}"
        )

        err
    end
  rescue
    e ->
      reason = {:saga_raised, Exception.message(e)}

      Logger.warning(
        "Ezagent.Kind.Runtime: saga effect raised; remaining effect " <>
          "buckets aborted: #{inspect(reason)}"
      )

      {:error, reason}
  catch
    kind, payload ->
      reason = {:saga_threw, kind, payload}

      Logger.warning(
        "Ezagent.Kind.Runtime: saga effect threw; remaining effect " <>
          "buckets aborted: #{inspect(reason)}"
      )

      {:error, reason}
  end

  # `:dispatch` effects — re-enter `Ezagent.Router.dispatch/1` for
  # each `%Cmd{}`. Sequential, in declared order. The Router does
  # NOT call back into THIS module's execute_buckets in Phase 1.5b
  # (it goes through `Ezagent.Invocation.dispatch/1` → another
  # Kind's `Kind.Server` → its own `handle_dispatch/4` → its own
  # `apply_new_contract_effects/4` if that target is new-style). No
  # re-entrancy concern at the executor level.
  #
  # First failing dispatch aborts the rest. The dispatch error is
  # propagated as `{:error, {:effect_dispatch_failed, reason}}` so
  # the caller can distinguish "my handler failed" vs "an effect
  # dispatch failed".
  defp execute_dispatches([], _ctx), do: :ok

  defp execute_dispatches([{:dispatch, %Ezagent.Cmd{} = cmd} | rest], ctx) do
    enriched_cmd = enrich_dispatch_cmd(cmd, ctx)

    case Ezagent.Router.dispatch(enriched_cmd) do
      :ok ->
        execute_dispatches(rest, ctx)

      {:ok, _result} ->
        execute_dispatches(rest, ctx)

      {:error, reason} ->
        Logger.warning(
          "Ezagent.Kind.Runtime: :dispatch effect failed; aborting remaining " <>
            "effects: target=#{inspect(cmd.target)} action=#{inspect(cmd.action)} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, {:effect_dispatch_failed, reason}}
    end
  end

  # Propagate the dispatching Kind's identity into the Cmd's ctx
  # when the handler-supplied Cmd left them blank. The handler is
  # NOT required to set `caller` (most won't — the Cmd is a
  # downstream effect, so "caller = self_uri" is the natural
  # default). `trace_id` propagation likewise lets correlated
  # traces span effect-chain dispatches.
  defp enrich_dispatch_cmd(%Ezagent.Cmd{ctx: cmd_ctx} = cmd, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    trace_id = Map.get(ctx, :trace_id)

    new_ctx =
      cmd_ctx
      |> maybe_put_default(:caller, self_uri)
      |> maybe_put_default(:trace_id, trace_id)

    %{cmd | ctx: new_ctx}
  end

  defp maybe_put_default(map, _key, nil), do: map

  defp maybe_put_default(map, key, default) do
    case Map.get(map, key) do
      :system -> Map.put(map, key, default)
      nil -> Map.put(map, key, default)
      _ -> map
    end
  end

  # `:notify` effects — `Phoenix.PubSub.broadcast/3`. Fire-and-
  # forget; broadcasts are observational and their failure NEVER
  # halts the dispatch. We log a warning on broadcast failure
  # (return value `{:error, _}`) but continue.
  defp execute_notifies([]), do: :ok

  defp execute_notifies([{:notify, topic, payload} | rest]) do
    case Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Ezagent.Kind.Runtime: :notify broadcast failed (continuing): " <>
            "topic=#{inspect(topic)} reason=#{inspect(reason)}"
        )
    end

    execute_notifies(rest)
  end

  # `:emit` effects → `Ezagent.EventLog.append/4`. Each event
  # becomes a row in the audit log. Audit failures NEVER halt the
  # dispatch (audit is observational) but ARE logged.
  #
  # The aggregate URI for the events is `ctx[:self_uri]` (the Kind
  # whose handler ran). `workspace_uri` is derived via
  # `Ezagent.Capability.workspace_of/1` on `self_uri`.
  defp execute_events([], _ctx), do: :ok

  defp execute_events(events, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    if is_nil(self_uri) do
      # No aggregate URI available — Kind.Runtime was invoked
      # without a self_uri (test-time or pathological). Skip
      # audit; log once at debug level so the conditional silence
      # is grep-able.
      Logger.debug(
        "Ezagent.Kind.Runtime: :emit effects produced but ctx[:self_uri] " <>
          "is nil; skipping EventLog append for #{length(events)} event(s)"
      )

      :ok
    else
      workspace_uri = derive_workspace_uri(self_uri)
      caller = normalize_caller_for_audit(Map.get(ctx, :caller))
      trace_id = Map.get(ctx, :trace_id)

      event_ctx = %{
        caller: caller,
        workspace_uri: workspace_uri,
        trace_id: trace_id
      }

      Enum.each(events, fn {:emit, event_name, payload} ->
        try do
          case Ezagent.EventLog.append(self_uri, event_name, payload, event_ctx) do
            {:ok, _event_id} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "Ezagent.Kind.Runtime: :emit EventLog.append failed (continuing): " <>
                  "event=#{inspect(event_name)} reason=#{inspect(reason)}"
              )
          end
        rescue
          e ->
            Logger.warning(
              "Ezagent.Kind.Runtime: :emit EventLog.append raised (continuing): " <>
                "event=#{inspect(event_name)} #{Exception.message(e)}"
            )
        catch
          # Repo unavailable / DBConnection checkout exits / etc.
          # Audit is observational — never halt the dispatch on it.
          kind, payload_caught ->
            Logger.warning(
              "Ezagent.Kind.Runtime: :emit EventLog.append threw (continuing): " <>
                "event=#{inspect(event_name)} kind=#{inspect(kind)} payload=#{inspect(payload_caught)}"
            )
        end
      end)

      :ok
    end
  end

  # `Ezagent.EventLog.append/4`'s `:caller` accepts only nil / URI /
  # binary. The dispatch ctx may carry `:system` (atom) for internal
  # callers — translate to nil so the audit row records "system" as
  # "no entity caller" instead of FunctionClauseError'ing inside
  # EventLog's URI helper.
  defp normalize_caller_for_audit(:system), do: nil
  defp normalize_caller_for_audit(nil), do: nil
  defp normalize_caller_for_audit(%URI{} = u), do: u
  defp normalize_caller_for_audit(s) when is_binary(s), do: s
  defp normalize_caller_for_audit(_), do: nil

  # Best-effort workspace derivation — `Capability.workspace_of/1`
  # returns `:any` for cross-cutting schemes. EventLog requires a
  # binary / URI; fall back to a `workspace://system` placeholder
  # when the URI doesn't have a real workspace (rare; mostly
  # `system://` principals + cross-cutting templates).
  defp derive_workspace_uri(%URI{} = self_uri) do
    case Ezagent.Capability.workspace_of(self_uri) do
      :any -> "workspace://system"
      %URI{} = ws -> ws
      bin when is_binary(bin) -> bin
      _ -> "workspace://system"
    end
  rescue
    _ -> "workspace://system"
  end

  defp derive_workspace_uri(_), do: "workspace://system"

  # `:terminate` effects → `Ezagent.Kind.terminate/1`. Each entry
  # is `{:terminate, :self | URI.t()}`. `:self` resolves to
  # `ctx[:self_uri]`. Idempotent (already-absent → :ok); failures
  # are swallowed by `Kind.terminate/1` per its contract.
  defp execute_terminations([], _ctx), do: :ok

  defp execute_terminations(terminations, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    Enum.each(terminations, fn
      {:terminate, :self} ->
        if is_nil(self_uri) do
          Logger.debug(
            "Ezagent.Kind.Runtime: :terminate :self requested but ctx[:self_uri] " <>
              "is nil; skipping"
          )
        else
          _ = Ezagent.Kind.terminate(self_uri)
        end

      {:terminate, %URI{} = target_uri} ->
        _ = Ezagent.Kind.terminate(target_uri)

      {:terminate, other} ->
        Logger.warning(
          "Ezagent.Kind.Runtime: :terminate effect target not a URI (skipping): " <>
            inspect(other)
        )
    end)

    :ok
  end

  defp handler_atom_for(action) when is_atom(action) do
    # Use `to_existing_atom/1` — `use Ezagent.Behavior` already
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

  # Phase 7 PR 43 — derive session URI from target URI for ctx enrichment.
  #
  # Sources covered:
  # - `session://default/team-alpha/main?action=chat.send` → `session://default/team-alpha/main` (legacy 1-seg)
  # - `session://default/team-alpha/main` → `session://default/team-alpha/main` (already session)
  # - `entity://agent/team-alpha/cc_demo?action=chat.receive` → nil (not session-targeted)
  # - any non-session URI → nil
  #
  # Pure URI manipulation; no registry / dispatch / GenServer involvement.
  # Returning `nil` for non-session targets is correct — a cap with
  # `{:within_session, S}` shape should not match when the dispatch
  # isn't even session-scoped, and `Capability.instance_match?/2` is
  # designed to handle nil session_uri (returns false for the tuple
  # case, preserving deny-as-default).
  # Allen 2026-05-26 (codex CRIT-1 closure) — inject the OPT-IN
  # `ctx[:sibling_slices]` read view scoped to ONLY the slice keys the
  # Behavior declared via `Ezagent.Behavior.reads_sibling_slices/0`
  # (legacy) / `reads_siblings/0` (Lifecycle rename, SPEC §2.2).
  #
  # Lifecycle Phase A (SPEC §2.2 / §7 OQ-7, F2) — the Phase B coexistence
  # invariant: conversion order must NOT matter. A sibling slice may be
  # legacy-flat (`%{keys: ...}`) OR Lifecycle two-container
  # (`%{state: %{keys: ...}, transients: %{}}`) depending on whether that
  # sibling's module has been converted yet. We NORMALIZE every two-
  # container sibling to its persistent `:state` view so a legacy reader
  # (`ctx.sibling_slices[:api_keys][:keys]`) sees flat fields unchanged
  # regardless of the sibling's conversion state. We ALSO surface the
  # SPEC-promised Lifecycle `ctx.siblings` map (same normalized-flat
  # shape) for converted modules that read `ctx.siblings[:api_keys]`.
  # Both keys carry the SAME normalized-flat values, so ANY mix of
  # legacy/Lifecycle siblings + ANY mix of legacy/Lifecycle readers on
  # one Kind is correct.
  #
  # Read-only by Behavior contract; the Runtime ignores any mutation to
  # either ctx key — only the dispatching Behavior's own slice is the
  # writable target.
  defp maybe_inject_sibling_slices(ctx, behavior_module, state) do
    case Ezagent.Behavior.reads_siblings_of(behavior_module) do
      [] ->
        ctx

      keys when is_list(keys) ->
        siblings =
          for key <- keys, into: %{} do
            {key, normalize_sibling_slice(Map.get(state, key, %{}))}
          end

        ctx
        |> Map.put(:sibling_slices, siblings)
        |> Map.put(:siblings, siblings)
    end
  end

  # Normalize a sibling slice to its persistent flat view. A Lifecycle
  # two-container slice (`%{state: _, transients: _}`) collapses to its
  # `:state` sub-map; a legacy flat slice passes through unchanged. This
  # is what makes a reader's `ctx.siblings[:api_keys][:keys]` resolve
  # whether or not `:api_keys` has been converted to Lifecycle yet.
  defp normalize_sibling_slice(%{state: st, transients: _} = _slice) when is_map(st), do: st
  defp normalize_sibling_slice(other), do: other

  defp derive_session_uri(%URI{scheme: "session"} = target) do
    # PR #141 SPEC v2: session URIs are `session://<type>/<name>`
    # (uniform 2-segment). Use Ezagent.URI.instance/1 to strip any
    # sub-resource so the result is the canonical instance form.
    Ezagent.URI.instance(target)
  end

  defp derive_session_uri(_other), do: nil
end
