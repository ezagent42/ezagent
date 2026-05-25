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

    with {:ok, {behavior_name_atom, action}} <- Ezagent.URI.behavior_action(target),
         {:ok, behavior_module} <- lookup_behavior(kind_module, action),
         :ok <- authz_check(behavior_module, kind_module, action, target, enriched_ctx),
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

  # PR-CC-2b (SPEC caps-cleanup-v1 §5.3 — partial) — dual-path cap check.
  #
  # During PR-CC-2b's transitional window, dispatch evaluates BOTH:
  #
  # 1. **Legacy path** (`Capability.matches?/2` against `ctx.caps`) — preserved
  #    so existing call sites that pass `caps: SystemPrincipal.caps(...)` (a
  #    `MapSet` of `%Capability{}` wildcard structs) keep authorizing while
  #    PR-CC-2c migrates them.
  #
  # 2. **New string-cap path** (`Behavior.required_caps/0` + `Kind.holds_cap?/2`
  #    against the caller's `:identity` slice) — the post-cleanup target.
  #    Looks up the needed cap string for `(behavior_module, action)`,
  #    substitutes any `*` kind segment with the target Kind's actual
  #    `type_name()`, then asks the caller's Kind whether the slice holds it.
  #
  # Grant if EITHER path authorizes. Deny ONLY if both deny. This means:
  # - Every test fixture that passes `ctx.caps` continues to work (legacy
  #   grants).
  # - System principals seeded as Kinds via `SystemPrincipal.ensure/1` exercise
  #   the new path when dispatched as `caller: system://<service>`.
  # - PR-CC-2c drops the legacy arm + migrates remaining call sites.
  #
  # Telemetry distinguishes the path that granted (`:via` in meta) so PR-CC-2c
  # can verify the legacy arm is unused before deletion.
  #
  # Per `feedback_let_it_crash_no_workarounds`: this is NOT a shim — both
  # implementations are first-class, the deny gate is "both deny", and the
  # transition is bounded (PR-CC-2c deletes the legacy arm). A shim would be
  # "if new fails, fall back to a default value" which we do not do.
  #
  # Order: legacy first, then the string-cap path runs ONLY if legacy denied.
  # The string-cap path does a `GenServer.call(:ezagent_get_slice, ...)`
  # which contends with the Kind.Server's snapshot-write path under heavy
  # parallel load (observed in CrossWorkspaceIsolationTest during PR-CC-2b
  # development). The discovery cost only fires on legacy-deny, which is
  # the case where we WANT the new path to have a chance — legacy-grant
  # was already going to succeed regardless.
  defp authz_check(behavior_module, kind_module, action, target, ctx) do
    legacy_needed = Ezagent.Capability.cap_for_action(kind_module, action, target)
    legacy_granted? = legacy_caps_match?(ctx, legacy_needed)

    meta_base = %{
      behavior_module: behavior_module,
      kind_module: kind_module,
      action: action,
      target: target,
      caller: Map.get(ctx, :caller),
      needed: legacy_needed
    }

    cond do
      legacy_granted? ->
        :telemetry.execute(
          [:ezagent, :authz, :granted],
          %{},
          Map.put(meta_base, :via, :legacy_struct)
        )

        :ok

      true ->
        # Legacy denied → try the new string-cap path.
        case string_cap_check(behavior_module, kind_module, action, target, ctx) do
          {needed_string, true} ->
            :telemetry.execute(
              [:ezagent, :authz, :granted],
              %{},
              meta_base
              |> Map.put(:via, :string_cap)
              |> Map.put(:needed_cap, needed_string)
            )

            :ok

          {needed_string, false} ->
            :telemetry.execute(
              [:ezagent, :authz, :denied],
              %{},
              Map.put(meta_base, :needed_cap, needed_string)
            )

            {:error, :unauthorized}
        end
    end
  end

  defp legacy_caps_match?(ctx, needed) do
    caps = Map.get(ctx, :caps, MapSet.new())

    Enum.any?(caps, fn cap ->
      Ezagent.Capability.matches?(cap, needed)
    end)
  end

  # String-cap path (PR-CC-2b new arm).
  #
  # Looks up `needed_cap = behavior.required_caps()[action]`, performs the
  # wildcard-kind substitution (Behaviors registered against multiple Kinds
  # declare the kind segment as `*` — substitute it with the target Kind's
  # actual `type_name()` so concrete-kind caps held by the caller match),
  # and asks the caller's Kind whether it holds that cap via
  # `Kind.holds_cap?/3` against its `:identity` slice.
  #
  # Returns `{needed_string | nil, granted_boolean}` so telemetry can record
  # what was checked even on denial.
  #
  # Special cases:
  # - `caller == :system` or `caller == nil`: returns `{needed_string, false}`.
  #   These callers do not have an Identity slice to consult — the legacy
  #   path handles them via `ctx.caps`. (PR-CC-2c will spawn `system://*`
  #   principal Kinds and migrate these sites to use real callers.)
  # - Behavior doesn't export `required_caps/0`, or the action isn't in the
  #   map: returns `{nil, false}` — let the legacy path decide. Per memory
  #   `feedback_let_it_crash_no_workarounds`, the assertive deny only fires
  #   once the new path is the sole arm (PR-CC-2c).
  defp string_cap_check(behavior_module, kind_module, action, target, ctx) do
    case Ezagent.Behavior.required_cap_for(behavior_module, action) do
      nil ->
        {nil, false}

      raw_needed when is_binary(raw_needed) ->
        target_kind = target_kind_module(target, kind_module)
        needed = substitute_wildcard_kind(raw_needed, target_kind)
        granted? = caller_holds_string_cap?(Map.get(ctx, :caller), needed)
        {needed, granted?}
    end
  end

  # Substitute `*` in the kind segment of a cap string with the target Kind's
  # actual `type_name()`. Behaviors registered against multiple Kinds (Routing
  # on Workspace+Session+System; Chat `:receive` on User+Agent; Identity on
  # User+Agent; IdentityAdmin on User+Agent) declare the kind segment as `*`
  # because the required cap is per-target-Kind. Without substitution, a
  # holder with concrete cap `session.chat.receive` would not match the
  # wildcard needed `*.chat.receive` (the matcher's wildcard-in-held semantics
  # are asymmetric — wildcard on held authorizes everything, wildcard on
  # needed is treated as a literal `*` segment).
  #
  # Only the FIRST segment is substituted. `cap-strings` with `*` in
  # behavior or action segments are left as-is — that shape is reserved for
  # an authorized holder (e.g. `session.*` granting all session-kind actions
  # of any behavior).
  @doc false
  @spec substitute_wildcard_kind(String.t(), module()) :: String.t()
  def substitute_wildcard_kind(needed_cap_string, target_kind_module)
      when is_binary(needed_cap_string) and is_atom(target_kind_module) do
    case String.split(needed_cap_string, ".", parts: 3) do
      ["*", behavior, action] ->
        target_kind = type_name_string(target_kind_module)
        Enum.join([target_kind, behavior, action], ".")

      ["*", behavior] ->
        target_kind = type_name_string(target_kind_module)
        Enum.join([target_kind, behavior], ".")

      _ ->
        needed_cap_string
    end
  end

  # Derive the target Kind module from the target URI. The Kind module
  # hosting THIS dispatch is `kind_module` (from the GenServer state), which
  # is the right answer for intra-Kind dispatches — and for the
  # cross-Kind-registered Behaviors (Chat on User+Agent, etc.) the target's
  # Kind module IS the Kind module currently handling the dispatch. So this
  # is a passthrough today; isolated as a function so future schemes (e.g.
  # facade Tasks routing across Kinds) can override.
  defp target_kind_module(_target, kind_module), do: kind_module

  defp type_name_string(kind_module) do
    kind_module
    |> apply(:type_name, [])
    |> Atom.to_string()
  rescue
    _ ->
      # Defensive — every Kind exports type_name/0 (it's a required
      # callback). The rescue covers a hypothetical mis-declared module
      # reaching dispatch; rather than crash dispatch we leave the
      # wildcard unresolved (which denies) and let the legacy arm or a
      # later test catch it.
      "*"
  end

  # Look up the caller's identity slice and call `Kind.holds_cap?/2`.
  # Returns false for `nil` / `:system` / `:any` (atom) callers and for
  # unspawned URIs.
  #
  # We use the DEFAULT `Kind.holds_cap?/2` (no Kind-module override) here.
  # Override via `Kind.holds_cap?/3` is reserved for Kinds with a
  # non-standard cap source — none ship today; PR-CC-2c+ will wire them
  # if they appear.
  defp caller_holds_string_cap?(nil, _needed), do: false
  defp caller_holds_string_cap?(:system, _needed), do: false
  defp caller_holds_string_cap?(:any, _needed), do: false

  defp caller_holds_string_cap?(%URI{} = caller_uri, needed) when is_binary(needed) do
    case Ezagent.Kind.get_slice(caller_uri, :identity) do
      {:ok, identity_slice} when is_map(identity_slice) ->
        # `Kind.holds_cap?/2` reads `slice[:identity][:caps]` — but
        # `get_slice/2` returns the slice DIRECTLY (i.e. what would be
        # at `state[:identity]`). Wrap it back so the default
        # implementation's `get_in(slice, [:identity, :caps])` finds the
        # cap list.
        Ezagent.Kind.holds_cap?(%{identity: identity_slice}, needed)

      _ ->
        false
    end
  end

  defp caller_holds_string_cap?(_other, _needed), do: false

  # Phase 9 PR-4 (SPEC v3 §5) step 5.6 — workspace isolation.
  #
  # PR-CC-2b (SPEC caps-cleanup-v1 §5.5) — gated on `Behavior.workspace_scoped?/0`.
  # Behaviors operating on cross-cutting data (system://, template://,
  # resource://) override `workspace_scoped?/0` to `false` and skip this
  # check entirely (`Ezagent.Behavior.Routing` is the canonical example —
  # routing rules live on scope-owning Kinds across workspaces). For
  # backwards-compat, Behaviors that haven't migrated default to `true`
  # via `Ezagent.Behavior.workspace_scoped?/1`'s probe fallback.
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
