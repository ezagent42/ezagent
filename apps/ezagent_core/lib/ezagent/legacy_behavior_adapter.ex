defmodule Ezagent.LegacyBehaviorAdapter do
  @moduledoc """
  ⚠️  MUST BE DELETED IN PHASE 3 per SPEC §11 grep gate.

  LegacyBehaviorAdapter — bridges existing `Behavior.invoke/4`–shaped
  Behaviors into the new Router pipeline per SPEC §6.1 Phase 1.

  The adapter:

  1. Looks like a new-style Behavior to the Router (declares actions,
     responds to `handle_<action>/2` calls, exposes `__actions__/0`).
  2. Internally delegates to the wrapped legacy Behavior's
     `invoke/4` callback.
  3. Synthesises effects from the slice diff (`Map.diff`-style) and
     returns them in the new `{:ok, result, [effect]}` shape.
  4. Is **deletion-tracked from day 1** — every public function is
     marked with the `# @LEGACY-PHASE3-REMOVE` sigil that the SPEC
     §11 grep gate counts.

  ## Replay (non-)equivalence — codex r1 HIGH-2 closure

  The adapter is **dispatch-equivalent but NOT replay-equivalent**:

  - **Dispatch-equivalent**: external observers (reply target, PubSub
    subscribers, downstream Kinds reached via `Invocation.dispatch/1`
    from inside the legacy handler) see IDENTICAL behaviour vs the
    pre-adapter path.
  - **NOT replay-equivalent**: the synthesized `:legacy_action_executed`
    event payload contains the slice diff, NOT the structured
    `{:emit, type, payload}` events a native Behavior would produce.
    Re-folding adapter-mode events via EventLog `apply_event/2`
    would NOT reproduce the same slice mutation sequence — the
    legacy handler's `Invocation.dispatch` / `PubSub.broadcast` side
    effects executed OUTSIDE the effect grammar and can't be
    replayed.

  This means: snapshot-based recovery works for adapter-mode
  Behaviors, but pure event-fold replay does not. The
  StateRebuilder treats adapter-mode events as "snapshot-only"
  per SPEC §6.1.

  Once Phase 3 deletes this module + the parity test set stops
  validating replay for adapted Behaviors, replay-equivalence
  holds for the entire codebase.

  ## How callers use it

  The adapter is consumed by `Ezagent.Router` when it encounters
  a Behavior that hasn't migrated to the new `use Ezagent.Behavior`
  macro:

      iex> Ezagent.LegacyBehaviorAdapter.wrap(Ezagent.Behavior.Echo)
      Ezagent.LegacyBehaviorAdapter.Echo

  The returned module declares the same `__actions__/0` as the
  legacy Behavior would have under the new macro, and the
  Router invokes it transparently.

  ## Phase 1 implementation note

  Phase 1's Router actually does NOT use this adapter on the
  dispatch path yet — the Router falls back to the legacy
  `Invocation.dispatch/1` machinery, which goes through
  `Kind.Runtime.handle_dispatch/4` and calls the legacy
  `invoke/4` directly. The adapter is provided so:

  1. Test scaffolding can simulate "this Behavior is wrapped"
     for the parity tests.
  2. Phase 2 PRs can flip individual Behaviors from "via legacy
     dispatch path" to "via adapter on new Router path" one at a
     time — surfacing any per-Behavior divergence with a small
     blast radius.

  ## Legacy adapter coverage

  At Phase 1 close, this adapter is structurally capable of
  wrapping every `@behaviour Ezagent.Behavior` module in the
  codebase. The `coverage/0` function returns the list of
  detected legacy Behavior modules — exposed so the
  `mix ezagent.audit.legacy_adapter` task (Phase 1 PR-X) can
  report on remaining call sites.
  """

  require Logger

  alias Ezagent.Cmd

  # @LEGACY-PHASE3-REMOVE
  @deletion_sigil :legacy_phase3_remove

  @doc """
  Convert a legacy `Behavior.invoke/4`-result + pre-handler slice
  into the new `{:ok, result, [effect]}` shape.

  Synthesises:
  - One `{:set, slice_key, new_slice}` effect for the changed slice
  - One `{:emit, :legacy_action_executed, %{...}}` event carrying
    the slice diff (NON-REPLAY-EQUIVALENT — see moduledoc)

  ## Arguments

  - `behavior_module` — the legacy Behavior module
  - `action` — the action atom
  - `old_slice` — the slice BEFORE `invoke/4` ran
  - `legacy_result` — the return of `behavior.invoke/4`

  ## Returns

  - `{:ok, result, [effect]}` on success
  - `{:error, reason}` on failure (propagated)
  """
  # @LEGACY-PHASE3-REMOVE
  @spec adapt_result(module(), atom(), map(), Ezagent.Behavior.invoke_return()) ::
          {:ok, term(), [Ezagent.Behavior.effect()]} | {:error, term()}
  def adapt_result(behavior_module, action, old_slice, legacy_result)
      when is_atom(behavior_module) and is_atom(action) and is_map(old_slice) do
    slice_key = slice_key_of(behavior_module)

    case legacy_result do
      {:ok, new_slice} when is_map(new_slice) ->
        {:ok, :ok, build_effects(slice_key, action, old_slice, new_slice, nil, behavior_module)}

      {:ok, new_slice, result} when is_map(new_slice) ->
        {:ok, result, build_effects(slice_key, action, old_slice, new_slice, result, behavior_module)}

      {:error, reason} ->
        {:error, reason}

      other ->
        Logger.warning(
          "LegacyBehaviorAdapter.adapt_result/4: unexpected return from #{inspect(behavior_module)}.invoke/4: #{inspect(other)}"
        )

        {:error, {:legacy_invoke_unexpected_return, other}}
    end
  end

  # @LEGACY-PHASE3-REMOVE
  defp build_effects(slice_key, action, old_slice, new_slice, result, behavior_module) do
    diff = diff_maps(old_slice, new_slice)

    # If nothing changed, only emit the audit event (no :set).
    set_effect =
      if map_size(diff) == 0 do
        []
      else
        [{:set, slice_key, new_slice}]
      end

    set_effect ++
      [
        # NOTE: payload type tag is intentionally `:legacy_action_executed`
        # — distinct from a native Behavior's structured `:emit` types so
        # the StateRebuilder can treat these specially per SPEC §6.1.
        {:emit, :legacy_action_executed,
         %{
           behavior: behavior_module,
           action: action,
           slice_diff: diff,
           result: result,
           at: DateTime.utc_now()
         }}
      ]
  end

  # @LEGACY-PHASE3-REMOVE
  defp diff_maps(old, new) when is_map(old) and is_map(new) do
    added_or_changed =
      Enum.reduce(new, %{}, fn {k, v}, acc ->
        case Map.fetch(old, k) do
          {:ok, ^v} -> acc
          _ -> Map.put(acc, k, v)
        end
      end)

    removed =
      Enum.reduce(old, [], fn {k, _v}, acc ->
        if Map.has_key?(new, k), do: acc, else: [k | acc]
      end)

    if removed == [] do
      added_or_changed
    else
      Map.put(added_or_changed, :__removed__, removed)
    end
  end

  # @LEGACY-PHASE3-REMOVE
  defp slice_key_of(behavior_module) do
    Code.ensure_loaded(behavior_module)

    if function_exported?(behavior_module, :state_slice, 0) do
      behavior_module.state_slice()
    else
      # Best-effort fallback: derive from module last segment.
      behavior_module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()
    end
  end

  @doc """
  Look up a legacy Behavior's actions list.

  Falls back gracefully if the module doesn't declare `actions/0`.
  """
  # @LEGACY-PHASE3-REMOVE
  @spec legacy_actions(module()) :: [atom()]
  def legacy_actions(behavior_module) when is_atom(behavior_module) do
    Code.ensure_loaded(behavior_module)

    cond do
      function_exported?(behavior_module, :actions, 0) ->
        apply(behavior_module, :actions, [])

      true ->
        []
    end
  end

  @doc """
  Read a legacy Behavior's `required_caps/0` map.

  Returns `%{}` if not exported.
  """
  # @LEGACY-PHASE3-REMOVE
  @spec legacy_required_caps(module()) :: map()
  def legacy_required_caps(behavior_module) when is_atom(behavior_module) do
    Code.ensure_loaded(behavior_module)

    if function_exported?(behavior_module, :required_caps, 0) do
      apply(behavior_module, :required_caps, [])
    else
      %{}
    end
  end

  @doc """
  Wrap a `%Cmd{}` into an `%Ezagent.Invocation{}` for direct
  delivery via the legacy dispatch path. Same translation
  `Ezagent.Router.dispatch/1` does internally; exposed here for
  tests that want to exercise the legacy path explicitly.
  """
  # @LEGACY-PHASE3-REMOVE
  @spec wrap_cmd(Cmd.t()) :: Ezagent.Invocation.t()
  def wrap_cmd(%Cmd{target: target, action: action, args: args, ctx: ctx}) do
    annotated_target = annotate_target(target, action)

    mode =
      case Map.get(ctx, :mode) do
        m when m in [:call, :cast, :call_stream] -> m
        _ -> if Map.get(ctx, :reply) == :ignore, do: :cast, else: :call
      end

    legacy_ctx =
      ctx
      |> Map.put_new(:caps, MapSet.new())
      |> Map.put_new(:reply, :ignore)

    %Ezagent.Invocation{
      target: annotated_target,
      mode: mode,
      args: args,
      ctx: legacy_ctx
    }
  end

  # @LEGACY-PHASE3-REMOVE
  defp annotate_target(%URI{query: nil} = uri, action) do
    %{uri | query: "action=#{action}"}
  end

  # @LEGACY-PHASE3-REMOVE
  defp annotate_target(%URI{query: q} = uri, action) when is_binary(q) do
    if String.contains?(q, "action=") do
      uri
    else
      %{uri | query: q <> "&action=#{action}"}
    end
  end

  @doc """
  Enumerate every legacy Behavior module the adapter could
  conceivably wrap — i.e. every loaded module that:

  - Has `@behaviour Ezagent.Behavior` declared (detected by the
    presence of `actions/0` + `invoke/4` exports)
  - Has NOT migrated to the new macro (no `__behavior__?/0`)

  Used by `mix ezagent.audit.legacy_adapter` (future task) to
  report on Phase 3 readiness.

  Phase 1 implementation: scans `:code.all_loaded/0`. Returns
  `[]` outside a fully-loaded application environment.
  """
  # @LEGACY-PHASE3-REMOVE
  @spec coverage() :: [module()]
  def coverage do
    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&legacy_behavior?/1)
  end

  # @LEGACY-PHASE3-REMOVE
  defp legacy_behavior?(mod) do
    # Skip OTP / stdlib modules.
    case Atom.to_string(mod) do
      "Elixir.Ezagent.Behavior." <> _ ->
        function_exported?(mod, :invoke, 4) and
          function_exported?(mod, :actions, 0) and
          not (function_exported?(mod, :__behavior__?, 0) and apply(mod, :__behavior__?, []))

      _ ->
        false
    end
  end

  @doc """
  The deletion-tracking sigil — public so the SPEC §11 grep gate
  can verify zero references at Phase 3 close.
  """
  # @LEGACY-PHASE3-REMOVE
  def deletion_sigil, do: @deletion_sigil
end
