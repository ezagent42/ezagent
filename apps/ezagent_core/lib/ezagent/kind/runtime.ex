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
  @type result ::
          {:ok, slice_state(), term()}
          | {:ok, slice_state()}
          | {:error, term()}

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
    enriched_ctx =
      ctx
      |> Map.put(:kind_module, kind_module)
      |> Map.put(:self_uri, self_uri)
      |> Map.put(:session_uri, derive_session_uri(target))

    with {:ok, {behavior_name_atom, action}} <- Ezagent.URI.behavior_action(target),
         {:ok, behavior_module} <- lookup_behavior(kind_module, action),
         :ok <- authz_check(kind_module, action, target, enriched_ctx),
         :ok <- workspace_isolation_check(target, enriched_ctx),
         :ok <- validate_args(behavior_module, action, args),
         slice_key <- behavior_module.state_slice(),
         slice <- Map.get(state, slice_key, %{}),
         {:ok, new_slice, result_or_nil} <-
           invoke_behavior(behavior_module, action, slice, args, enriched_ctx) do
      # Step 9 — put_in state. Snapshot wiring is Phase 1 step 3.
      new_state = Map.put(state, slice_key, new_slice)

      # Step 9.5 (SPEC v2 PR-N1, Allen 2026-05-24) — slice-change hook.
      # Notification v2: slice mutation IS the notification trigger.
      # `SliceChange.emit/1` is gated by config flag (default OFF
      # in N1; PR-N3 flips on), and short-circuits when slice
      # unchanged. NEVER fires on `{:error, _}` (we're inside the
      # success branch of the `with`).
      #
      # Codex PR-N1 round-1 HIGH-2 fix: use the BARE INSTANCE URI
      # for both topic and payload — `target` contains `?action=…`
      # query, but subscribers want one topic per Kind instance.
      # `Ezagent.URI.instance/1` strips query + fragment.
      if new_slice != slice do
        instance_uri = Ezagent.URI.instance(target)

        Ezagent.SliceChange.emit(%{
          self_uri: instance_uri,
          kind_module: kind_module,
          action: action,
          slice_key: slice_key,
          old_slice: slice,
          new_slice: new_slice,
          result: result_or_nil,
          caller: Map.get(enriched_ctx, :caller),
          at: DateTime.utc_now()
        })
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

      case result_or_nil do
        nil -> {:ok, new_state}
        result -> {:ok, new_state, result}
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

  # Phase 3d hard flip (per P3-D6): real cap check via Capability.matches?.
  # `:stub_grant` telemetry is GONE — replaced with `:granted` (success)
  # and `:denied` (failure). Per memory feedback_let_it_crash_no_workarounds:
  # no feature flag, no parallel paths; the alarm path is "this function
  # ever emits :stub_grant" which check_invariants #9 enforces.
  defp authz_check(kind_module, action, target, ctx) do
    needed = Ezagent.Capability.cap_for_action(kind_module, action, target)
    caps = Map.get(ctx, :caps, MapSet.new())

    granted? =
      Enum.any?(caps, fn cap ->
        Ezagent.Capability.matches?(cap, needed)
      end)

    meta = %{
      kind_module: kind_module,
      action: action,
      target: target,
      caller: Map.get(ctx, :caller),
      needed: needed
    }

    if granted? do
      :telemetry.execute([:ezagent, :authz, :granted], %{}, meta)
      :ok
    else
      :telemetry.execute([:ezagent, :authz, :denied], %{}, meta)
      {:error, :unauthorized}
    end
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
  defp workspace_isolation_check(target, ctx) do
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
  # - `session://default/default/main?action=chat.send` → `session://default/default/main` (legacy 1-seg)
  # - `session://default/default/main` → `session://default/default/main` (already session)
  # - `entity://agent/default/cc_demo?action=chat.receive` → nil (not session-targeted)
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
