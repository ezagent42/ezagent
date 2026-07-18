defmodule Ezagent.Router do
  @moduledoc """
  Router — the dispatch primitive per SPEC §2.1.

  Takes a `%Ezagent.Cmd{}` envelope and routes through the
  middleware pipeline:

  1. URI canonicalisation (`Ezagent.URI.instance/1`)
  2. Idempotency check via `ctx.command_uuid`
  3. Ready-gate consultation (`Ezagent.ReadyGate`)
  4. Behavior lookup (`BehaviorRegistry.lookup({kind_module, action})`)
  5. Capability check at dispatch boundary
  6. Workspace isolation check
  7. Args validation against the Behavior's `@interface`
  8. Read framework-managed state
  9. Invoke handler — `behavior.handle_<action>(args, ctx)`
  10. Apply effects in declared order (`Behavior.apply_effects/2`)
  11. EventLog append (audit) — stub in Phase 1 (Subagent B owns module)
  12. Snapshot commit — owned by Kind.Host
  13. Result post-processing (`Invocation.reply/2` per ctx.reply)

  ## Phase 1 implementation strategy

  Steps 1-7 reuse the existing `Ezagent.Invocation.dispatch/1` +
  `Ezagent.Kind.Runtime.handle_dispatch/4` pipeline by translating
  `%Cmd{}` → `%Invocation{}`. The `Cmd.action` populates the
  `?action=behavior.action` query string the legacy registry uses
  for routing. This keeps Phase 1 changes additive — every
  existing `Behavior.invoke/4` continues to work via the same
  pipeline.

  Phase 2 introduces direct handler invocation (`handle_<action>/2`
  with the new effect grammar) inside `Kind.Host.handle_call/cast`,
  bypassing the legacy `invoke/4` shim for new-style Behaviors.

  ## Audit + Saga stubs (Subagent B / D outputs)

  This Phase 1 build stubs calls to:

  - `Ezagent.EventLog.append/4` — Subagent B is implementing in
    parallel; this module compiles standalone by referencing the
    fully-qualified call via `Code.ensure_loaded?/1` runtime check
  - `Ezagent.SagaRunner.execute/2` — Subagent D, same approach

  Both calls are wrapped in `safe_call/3` so a not-yet-loaded
  module surfaces as a `Logger.debug` and the dispatch continues.
  Once Subagents B/D integrate, the stubs are no-ops in practice.
  """

  require Logger

  alias Ezagent.{Cmd, Invocation}
  # Other Ezagent modules are referenced fully-qualified to avoid
  # `Ezagent.URI` shadowing the stdlib URI we need for `%URI{}`
  # pattern matching.

  @type dispatch_error ::
          :unauthorized
          | :cross_workspace_denied
          | :no_such_actor
          | :not_ready
          | :unsupported_mode
          | {:unknown_action, atom()}
          | {:invalid_args, list()}
          | {:behavior_exception, term(), term()}
          | term()

  @type dispatch_result :: {:ok, term()} | :ok | {:error, dispatch_error()}

  @doc """
  Dispatch a `%Cmd{}` through the Router pipeline.

  Returns:
  - `{:ok, result}` — success with a return value
  - `:ok` — success (cast / fire-and-forget)
  - `{:error, reason}` — failure (see `t:dispatch_error/0`)
  """
  @spec dispatch(Cmd.t()) :: dispatch_result()
  def dispatch(%Cmd{} = cmd) do
    trace_id = cmd.ctx[:trace_id] || generate_trace_id()
    started_at = System.monotonic_time(:microsecond)

    # Audit start — best-effort (Subagent B's module may not be loaded yet).
    safe_call(Ezagent.EventLog, :append, [
      %{
        type: :router_dispatch_start,
        target: cmd.target,
        action: cmd.action,
        trace_id: trace_id,
        at: DateTime.utc_now()
      }
    ])

    result =
      cmd
      |> to_invocation()
      |> Invocation.dispatch()

    audit_dispatch_result(cmd, result, trace_id, started_at)

    normalize_result(result)
  end

  @doc """
  Run a saga via `Ezagent.SagaRunner.execute/2`.

  Returns `{:error, :saga_runner_not_loaded}` (a clean, documented
  signal — never a `FunctionClause` crash) when the runner cannot run
  the given input: either the `Ezagent.SagaRunner` module is not loaded,
  OR the supplied `saga` is not a `%Ezagent.SagaRunner.Saga{}` struct
  the runner knows how to execute. Both are "the runner is not in a
  position to run this" from the caller's perspective.

  When the runner is loaded and `saga` is a valid `%Saga{}`, this is a
  passthrough to `SagaRunner.execute/2`.
  """
  @spec dispatch_saga(term(), map()) ::
          {:ok, map()}
          | {:error, atom(), term(), [atom()]}
          | {:error, :saga_runner_not_loaded}
  def dispatch_saga(saga, ctx) when is_map(ctx) do
    runner_ready? =
      Code.ensure_loaded?(Ezagent.SagaRunner) and
        function_exported?(Ezagent.SagaRunner, :execute, 2)

    cond do
      not runner_ready? ->
        Logger.debug("Ezagent.Router.dispatch_saga/2 called but Ezagent.SagaRunner not loaded")
        {:error, :saga_runner_not_loaded}

      not is_struct(saga, Ezagent.SagaRunner.Saga) ->
        Logger.debug(
          "Ezagent.Router.dispatch_saga/2 called with a non-%Saga{} input " <>
            "(#{inspect(saga)}); the runner cannot execute it"
        )

        {:error, :saga_runner_not_loaded}

      true ->
        Ezagent.SagaRunner.execute(saga, ctx)
    end
  end

  # ---------------------------------------------------------------
  # Internal — Cmd → Invocation translation
  # ---------------------------------------------------------------

  # Build the `?action=behavior.action` URI shape the legacy
  # registry uses. Phase 1 keeps this translation in one place so
  # Phase 2's direct-handler path can bypass it cleanly.
  defp to_invocation(%Cmd{target: target, action: action, args: args, ctx: ctx, origin: origin}) do
    # The legacy dispatch path expects `target` to embed action as
    # the query-string. We append `?action=...` here when not
    # already present (caller may have pre-baked it).
    annotated_target = annotate_target_with_action(target, action)

    mode = derive_mode(ctx)

    legacy_ctx =
      ctx
      |> Map.put_new(:caps, MapSet.new())
      |> Map.put_new(:reply, :ignore)
      |> normalize_caps()

    %Invocation{
      target: annotated_target,
      mode: mode,
      args: args,
      ctx: legacy_ctx,
      origin: origin
    }
  end

  defp annotate_target_with_action(%Elixir.URI{query: nil} = uri, action) do
    %{uri | query: "action=#{action_query_value(action)}"}
  end

  defp annotate_target_with_action(%Elixir.URI{query: q} = uri, action) when is_binary(q) do
    if String.contains?(q, "action=") do
      uri
    else
      %{uri | query: q <> "&action=#{action_query_value(action)}"}
    end
  end

  # The legacy URI parser (`Ezagent.URI.behavior_action/1`)
  # expects the `action` query value to be `<behavior>.<action>`
  # — it splits on `.` and treats the LHS as a behavior-name
  # atom (for telemetry only — the actual registry lookup uses
  # `{kind_module, action_atom}`). Phase 1 Router doesn't know
  # the behavior name from a `%Cmd{}` alone, so we synthesise
  # `_.<action>` — the leading `_` is a sentinel telling the
  # legacy parser "this came from the new Router; ignore the
  # behavior-name slot". `String.to_atom("_")` produces `:_`
  # which is harmless in telemetry payloads.
  defp action_query_value(action) when is_atom(action) do
    "_." <> Atom.to_string(action)
  end

  defp derive_mode(%{mode: :call}), do: :call
  defp derive_mode(%{mode: :cast}), do: :cast
  defp derive_mode(%{mode: :call_stream}), do: :call_stream

  defp derive_mode(%{reply: :ignore}), do: :cast

  defp derive_mode(%{reply: {kind, _}})
       when kind in [
              :caller_inbox,
              :phoenix_pubsub,
              :phoenix_channel,
              :plug_conn,
              :stdio_pipe,
              :mcp_response
            ],
       do: :call

  defp derive_mode(_), do: :call

  # The legacy ctx expects `:caps` as a MapSet of `%Capability{}`
  # structs. New-style `%Cmd{}` callers may pass `nil` (caller is
  # `:vm_internal`) — we substitute the admin-equivalent empty set
  # rather than treat as a missing key.
  defp normalize_caps(%{caps: nil} = ctx), do: %{ctx | caps: MapSet.new()}
  defp normalize_caps(%{caps: %MapSet{}} = ctx), do: ctx
  defp normalize_caps(%{caps: list} = ctx) when is_list(list), do: %{ctx | caps: MapSet.new(list)}
  defp normalize_caps(ctx), do: Map.put(ctx, :caps, MapSet.new())

  # ---------------------------------------------------------------
  # Audit + result normalisation
  # ---------------------------------------------------------------

  defp audit_dispatch_result(cmd, result, trace_id, started_at) do
    elapsed_us = System.monotonic_time(:microsecond) - started_at

    type =
      case result do
        :ok -> :router_dispatch_ok
        {:ok, _} -> :router_dispatch_ok
        {:error, _} -> :router_dispatch_error
      end

    reason =
      case result do
        {:error, r} -> r
        _ -> nil
      end

    safe_call(Ezagent.EventLog, :append, [
      %{
        type: type,
        target: cmd.target,
        action: cmd.action,
        trace_id: trace_id,
        elapsed_us: elapsed_us,
        reason: reason,
        at: DateTime.utc_now()
      }
    ])
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _} = ok), do: ok
  defp normalize_result({:error, _} = err), do: err
  defp normalize_result(other), do: {:ok, other}

  # Generate a 16-byte hex trace id — same shape as
  # `Ezagent.Notifications.trace_id/0` but private to avoid the
  # circular dep risk during Phase 1 build.
  defp generate_trace_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------
  # safe_call — Subagent B/D stub helper
  # ---------------------------------------------------------------

  defp safe_call(mod, fun, args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      try do
        apply(mod, fun, args)
      rescue
        e ->
          Logger.debug(
            "Ezagent.Router stub call #{inspect(mod)}.#{fun}/#{length(args)} raised: #{Exception.message(e)}"
          )

          :ok
      end
    else
      # Module / fun not loaded — Phase 1 Subagent B (EventLog) or
      # D (SagaRunner) hasn't integrated yet. Silently skip.
      :ok
    end
  end
end
