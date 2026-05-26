defmodule Ezagent.Kind.Runtime do
  @moduledoc """
  In-process dispatch flow inside a Kind GenServer.

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
      # Allen 2026-05-26 — `:all_slices` injection: the full multi-Behavior
      # slice state for this Kind instance, so a Behavior whose invoke
      # legitimately needs to read a SIBLING slice can do so in-process
      # without a self-dispatch deadlock (`GenServer.call(self)`).
      # Example: `Behavior.CurlAgent.invoke(:receive, ...)` needs the
      # `:api_keys` slice on the same Agent to fetch the outbound LLM
      # credential; dispatching `?action=identity.get_api_key` back to
      # ctx.self_uri would hit the same Kind.Server and deadlock.
      # Read-only by contract — the Behavior MUST mutate ONLY its own
      # `slice` (the third arg to invoke); the Runtime ignores any
      # changes to ctx[:all_slices].
      |> Map.put(:all_slices, state)

    with {:ok, {behavior_name_atom, action}} <- Ezagent.URI.behavior_action(target),
         {:ok, behavior_module} <- lookup_behavior(kind_module, action),
         :ok <- authz_check(kind_module, behavior_module, action, target, enriched_ctx),
         :ok <- workspace_isolation_check(behavior_module, target, enriched_ctx),
         :ok <- validate_args(behavior_module, action, args),
         slice_key <- behavior_module.state_slice(),
         slice <- Map.get(state, slice_key, %{}),
         {:ok, new_slice, result_or_nil} <-
           invoke_behavior(behavior_module, action, slice, args, enriched_ctx) do
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
        if new_slice != slice do
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
       }) do
    %Ezagent.Capability{
      kind: k,
      behavior: b,
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

  defp invoke_behavior(behavior_module, action, slice, args, ctx) do
    case behavior_module.invoke(action, slice, args, ctx) do
      {:ok, new_slice} -> {:ok, new_slice, nil}
      {:ok, new_slice, result} -> {:ok, new_slice, result}
      {:error, _reason} = err -> err
    end
  catch
    kind, reason ->
      # Per Appendix A step 7 failure: caught; state untouched; DLQ
      # wiring lands in Phase 1 step 3. For now propagate the error.
      Logger.error(
        "Behavior #{inspect(behavior_module)}.invoke/#{action} crashed: " <>
          "#{inspect(kind)} #{inspect(reason)}"
      )

      {:error, {:behavior_exception, kind, reason}}
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
  defp derive_session_uri(%URI{scheme: "session"} = target) do
    # PR #141 SPEC v2: session URIs are `session://<type>/<name>`
    # (uniform 2-segment). Use Ezagent.URI.instance/1 to strip any
    # sub-resource so the result is the canonical instance form.
    Ezagent.URI.instance(target)
  end

  defp derive_session_uri(_other), do: nil
end
