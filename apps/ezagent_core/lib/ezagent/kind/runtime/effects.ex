defmodule Ezagent.Kind.Runtime.Effects do
  @moduledoc false

  require Logger

  @doc """
  Lifecycle signal effect application (T1 — Phase B foundation).

  Runs the SAME full effect pipeline as the action path
  (`apply_new_contract_effects/4`) for a `handle_signal/2` effect list:
  `Ezagent.ActionSet.apply_effects/2` (state + transient reduced pre-commit,
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
          [Ezagent.ActionSet.effect()],
          map()
        ) :: {:ok, %{state: map(), transients: map()}} | :ignore
  def apply_signal_effects(slice, effects, ctx) when is_list(effects) do
    case Ezagent.ActionSet.apply_effects(effects, slice) do
      {:ok, buckets} ->
        case execute_buckets(buckets, ctx) do
          # P2.5c — `execute_buckets/2` now returns the resolved
          # post-commit dispatches (`{:ok, deferred}`). The signal path is
          # NOT in a parent-commit context (there is no `commit_and_notify`
          # gate after a `handle_signal`), so it has nowhere to run deferred
          # dispatches — they are DROPPED here. The crash-recovery signal
          # (`Turn.handle_signal({:ezagent_recover_settlements}, _)`)
          # deliberately emits NORMAL `:dispatch` effects (run inline by
          # `execute_dispatches`), so its deferred list is always empty.
          {:ok, _deferred} ->
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
  # `Ezagent.ActionSet.apply_effects/2`.
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
  def apply_new_contract_effects(slice, result, effects, ctx) do
    case Ezagent.ActionSet.apply_effects(effects, slice) do
      {:ok, buckets} ->
        case execute_buckets(buckets, ctx) do
          # P2.5c — `execute_buckets/2` returns the RESOLVED + ENRICHED
          # post-commit dispatches as the 4th element. `Kind.Server` runs
          # them via `Router.dispatch` ONLY after `commit_and_notify`
          # durably persists the parent slice. A handler that emits no
          # `:dispatch_after_commit` gets `[]` — byte-for-byte unchanged.
          {:ok, deferred} ->
            {:ok, buckets.state, result, deferred}

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
      dispatches =
        Enum.map(buckets.dispatches, &Ezagent.ActionSet.substitute_refs(&1, returning2))

      notifies = Enum.map(buckets.notifies, &Ezagent.ActionSet.substitute_refs(&1, returning2))
      events = Enum.map(buckets.events, &Ezagent.ActionSet.substitute_refs(&1, returning2))

      with :ok <- execute_dispatches(dispatches, ctx) do
        execute_notifies(notifies)
        execute_events(events, ctx)
        execute_terminations(buckets.terminations, ctx)

        # P2.5c — RESOLVE (don't run) the post-commit dispatches with the
        # EXACT same treatment as the normal `:dispatch` bucket: second-pass
        # ref substitution against the full `returning2` map (effect_returning
        # + dispatch_returning bindings) THEN `enrich_dispatch_cmd/2` so a
        # handler-supplied Cmd without an explicit caller inherits the
        # emitting Kind's `self_uri` (NOT `:vm_internal` — codex HIGH: a raw
        # deferred Cmd would default to `caller: :vm_internal` and be authorized
        # as trusted in-VM). Return them resolved; `Kind.Server` runs them after the
        # parent slice durably commits.
        deferred =
          buckets
          |> Map.get(:dispatches_after_commit, [])
          |> Enum.map(&Ezagent.ActionSet.substitute_refs(&1, returning2))
          |> Enum.map(&enrich_dispatch_cmd(&1, ctx))

        {:ok, deferred}
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
      |> Ezagent.ActionSet.substitute_refs(returning_acc)
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
    authenticated_principal = Map.get(ctx, :authenticated_principal)

    new_ctx =
      cmd_ctx
      |> maybe_put_default(:caller, self_uri)
      |> maybe_put_default(:authenticated_principal, authenticated_principal)
      |> maybe_put_default(:trace_id, trace_id)

    %{cmd | ctx: new_ctx}
  end

  # Cap delivery is a fixed framework hand-off: `Identity.Grant` has already
  # authorized + signed the artifact, and the receiving Identity handler must
  # see the VM-internal storage principal. The producer marker distinguishes
  # that explicit hand-off from an ordinary handler-authored Cmd whose default
  # caller must be replaced with the emitting Kind URI.
  defp maybe_put_default(
         %{caller: :vm_internal, cap_delivery_producer: producer} = map,
         :caller,
         _default
       )
       when producer in [:identity_grant, :identity_revoke],
       do: map

  defp maybe_put_default(map, _key, nil), do: map

  defp maybe_put_default(map, key, default) do
    case Map.get(map, key) do
      :vm_internal -> Map.put(map, key, default)
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

  @doc """
  Emit a single Reputation `:receipt` fact into the EventLog.

  The reputation layer's factual exhaust: `Ezagent.Kind.Runtime` calls this on
  the SUCCESS path of an authorized cross-workspace ("cross-org") invocation.
  It reuses the exact `:emit`-effect append path (`execute_events/2`) so it
  inherits its guarantees: `workspace_uri` derived from the aggregate, caller
  normalized for audit, and — critically — EVERY EventLog failure swallowed
  (audit/receipt is observational and MUST NEVER halt or slow the dispatch).

  `aggregate_uri` is the provider (the target Kind instance the receipt is
  about); it is injected as `ctx[:self_uri]` for `execute_events/2`. Always
  returns `:ok`; the caller discards the return.
  """
  @spec emit_receipt(URI.t(), map(), map()) :: :ok
  def emit_receipt(%URI{} = aggregate_uri, payload, ctx) when is_map(payload) do
    execute_events([{:emit, :receipt, payload}], Map.put(ctx, :self_uri, aggregate_uri))
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
  # binary. The dispatch ctx may carry `:vm_internal` (atom) for trusted
  # in-VM callers — translate to nil so the audit row records it as
  # "no entity caller" instead of FunctionClauseError'ing inside
  # EventLog's URI helper.
  defp normalize_caller_for_audit(:vm_internal), do: nil
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
      :any -> system_workspace_uri_string()
      %URI{} = ws -> ws
      bin when is_binary(bin) -> bin
      _ -> system_workspace_uri_string()
    end
  rescue
    _ -> system_workspace_uri_string()
  end

  defp derive_workspace_uri(_), do: system_workspace_uri_string()

  defp system_workspace_uri_string, do: :system |> Ezagent.URI.workspace() |> URI.to_string()

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
end
