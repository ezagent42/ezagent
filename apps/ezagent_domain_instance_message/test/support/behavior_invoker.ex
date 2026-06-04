defmodule EzagentDomainInstanceMessage.Test.BehaviorInvoker do
  @moduledoc """
  Test-only helper that calls a new-contract Behavior handler
  (`handle_<action>(args, ctx)`) directly, folds the returned
  effect list into a slice, and lifts the 3-tuple result back
  into the `{:ok, slice} | {:ok, slice, result} | {:error,
  reason}` shape Behavior contract tests assert against.

  This is the new-contract counterpart of the (now-deleted) Phase
  3 `BehaviorLegacyInvoke` shim. It has the same surface
  (`invoke/5`, `invoke_with_effects/5`) but is no longer a
  translation layer — it calls the per-action handler directly
  and packages the result.

  ## Why this is test-only

  The Kind.Runtime dispatch path (`Ezagent.Kind.Runtime.handle_dispatch/4`)
  is the production entry point: it does authz, workspace
  isolation, arg validation, slice fetch from registered Kind
  state, snapshot writes, and slice-change emission. That entire
  pipeline is over-specified for a unit test that just wants to
  assert "given slice X and args Y, the handler returns Z and
  mutates the slice to W". This helper invokes ONLY the handler
  with the right ctx shape and applies `:set` effects against
  the passed-in slice — no registry, no snapshot, no PubSub
  beyond the per-handler `:notify` effects.

  ## Usage

      alias EzagentDomainInstanceMessage.Test.BehaviorInvoker, as: Invoker

      assert {:ok, new_slice, %{stored: true}} =
               Invoker.invoke(Ezagent.Behavior.Chat, :send, slice, %{message: msg}, ctx)

  Or with effect introspection:

      assert {:ok, new_slice, result, effects} =
               Invoker.invoke_with_effects(Ezagent.Behavior.Chat, :send, slice, %{message: msg}, ctx)
  """

  @doc """
  Call a Behavior's `handle_<action>(args, ctx)` clause and fold
  the returned effects into a slice + result.

  Returns `{:ok, new_slice} | {:ok, new_slice, result} | {:error, reason}`
  to match the legacy invoke contract test assertions used.
  """
  @spec invoke(module(), atom(), map(), map(), map()) ::
          {:ok, map()}
          | {:ok, map(), term()}
          | {:error, term()}
  def invoke(behavior_module, action, slice, args, ctx) do
    case invoke_with_effects(behavior_module, action, slice, args, ctx) do
      {:ok, new_slice, nil, _effects} ->
        {:ok, new_slice}

      # Handlers that return an empty-map result (e.g. fire-and-forget
      # `:receive`) collapse to the 2-tuple shape so legacy assertion
      # `{:ok, ^slice}` keeps working.
      {:ok, new_slice, result, _effects} when result == %{} ->
        {:ok, new_slice}

      {:ok, new_slice, result, _effects} ->
        {:ok, new_slice, result}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Same as `invoke/5` but also returns the effect list (for tests
  that want to assert the shape of emitted :notify / :dispatch
  effects).

  Returns `{:ok, new_slice, result, effects}` on success.
  """
  @spec invoke_with_effects(module(), atom(), map(), map(), map()) ::
          {:ok, map(), term() | nil, [term()]}
          | {:error, term()}
  def invoke_with_effects(behavior_module, action, slice, args, ctx) do
    handler = String.to_atom("handle_" <> Atom.to_string(action))

    # Lifecycle two-container support (SPEC 2026-05-29 §2.3): a converted
    # Behavior reads persistent fields via `ctx.read` (over the flat
    # slice here) and TRANSIENT fields via `ctx.transients[k]`, writing
    # transients with `{:set_transient, k, v}` effects. A flat (legacy)
    # slice has no separate transient container, so we expose the SAME
    # flat slice as `ctx.transients` — the transient keys (e.g.
    # `:monitors`) live alongside the persistent ones in the test's flat
    # slice, and `apply_set_effects/2` folds BOTH `:set` and
    # `:set_transient` back onto that one flat map. This is additive:
    # behaviors that emit no `:set_transient` are unaffected.
    enriched_ctx =
      ctx
      |> Map.put_new(:read, fn key, default -> Map.get(slice, key, default) end)
      |> Map.put_new(:transients, slice)

    if function_exported?(behavior_module, handler, 2) do
      case apply(behavior_module, handler, [args, enriched_ctx]) do
        {:ok, result, effects} when is_list(effects) ->
          new_slice = apply_set_effects(slice, effects)
          # Side-effect-shaped effects also need to actually run for
          # legacy assertion patterns to keep working — a test that
          # subscribes to PubSub before invoke and asserts_receive on
          # the broadcast expects the broadcast to actually happen.
          execute_notify_effects(effects)
          {:ok, new_slice, result, effects}

        {:ok, result} ->
          {:ok, slice, result, []}

        {:error, _reason} = err ->
          err

        other ->
          {:error, {:bad_handler_return, behavior_module, action, other}}
      end
    else
      {:error, {:missing_handler, behavior_module, handler}}
    end
  end

  # Folds BOTH `:set` (persistent) and `:set_transient` (volatile)
  # effects onto the single flat test slice. For a flat slice the two
  # containers are co-located, so a `{:set_transient, :monitors, m}`
  # writes `:monitors` back where the test reads it via `new_slice.monitors`.
  defp apply_set_effects(slice, effects) do
    Enum.reduce(effects, slice, fn
      {:set, key, value}, acc -> Map.put(acc, key, value)
      {:set_transient, key, value}, acc -> Map.put(acc, key, value)
      _other_effect, acc -> acc
    end)
  end

  defp execute_notify_effects(effects) do
    Enum.each(effects, fn
      {:notify, topic, payload} ->
        Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic, payload)

      _ ->
        :ok
    end)
  end
end
