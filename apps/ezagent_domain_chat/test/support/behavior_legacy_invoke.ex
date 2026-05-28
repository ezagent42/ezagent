defmodule EzagentDomainChat.Test.BehaviorLegacyInvoke do
  @moduledoc """
  Test-only shim translating legacy `Behavior.invoke(action, slice,
  args, ctx)` calls into the new SPEC 2026-05-28 contract's
  `handle_<action>(args, ctx_with_read) → {:ok, result, effects}`
  shape, then folding the effect list back into a slice + result
  the way `Ezagent.Kind.Runtime.apply_new_contract_effects/4` would.

  ## Why this exists

  P2-a r3 (2026-05-28) migrated `Ezagent.Behavior.Chat`,
  `Behavior.Template`, `Behavior.OrchestratorAdmin`, and
  `Behavior.Publisher.SessionImpl` to the new action grammar
  (`use Ezagent.Behavior` + `handle_<action>/2`). The legacy
  `def invoke(:foo, slice, args, ctx)` is gone, so test files that
  used it for unit coverage no longer compile.

  Rewriting every test would be the cleanest fix, but the existing
  tests carry useful structural assertions about each Behavior's
  side-effects + slice mutations. This shim lets them keep working
  with a single `s/Chat.invoke/BehaviorLegacyInvoke.invoke(Chat, /`
  substitution — the parity tests
  (`<basename>_migration_parity_test.exs`) cover the NEW shape
  directly.

  ## Limitations

  - The shim ONLY applies `:set` effects to the returned slice; other
    effects (`:notify`, `:dispatch`, etc.) are returned as a 4-tuple
    field for tests that want to assert their shape. Most legacy
    tests don't introspect effects — they assert `{:ok, new_slice,
    result}` shape only.
  - Handlers that read sibling slices via `ctx[:sibling_slices]` still
    need that key in the passed ctx — same as the legacy path.

  ## Usage

      alias EzagentDomainChat.Test.BehaviorLegacyInvoke, as: Shim

      assert {:ok, new_slice, %{stored: true}} =
               Shim.invoke(Ezagent.Behavior.Chat, :send, slice, %{message: msg}, ctx)

  Or with effect introspection:

      assert {:ok, new_slice, result, effects} =
               Shim.invoke_with_effects(Ezagent.Behavior.Chat, :send, slice, %{message: msg}, ctx)
  """

  @doc """
  Translate a legacy `Behavior.invoke(action, slice, args, ctx)`
  call into a `handle_<action>(args, ctx)` call + effect-fold.

  Returns the same `{:ok, new_slice} | {:ok, new_slice, result} |
  {:error, reason}` shapes the legacy invoke contract used.
  """
  @spec invoke(module(), atom(), map(), map(), map()) ::
          {:ok, map()}
          | {:ok, map(), term()}
          | {:error, term()}
  def invoke(behavior_module, action, slice, args, ctx) do
    case invoke_with_effects(behavior_module, action, slice, args, ctx) do
      {:ok, new_slice, nil, _effects} ->
        {:ok, new_slice}

      # Pre-migration `:receive` returned `{:ok, slice}` (2-tuple) —
      # post-migration handlers return `{:ok, %{}, [effects]}` (3-tuple
      # with empty-map result). Collapse the empty-map result to the
      # 2-tuple shape so legacy assertion `{:ok, ^slice}` keeps
      # working.
      {:ok, new_slice, result, _effects} when result == %{} ->
        {:ok, new_slice}

      {:ok, new_slice, result, _effects} ->
        {:ok, new_slice, result}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Same as `invoke/5` but also returns the effect list (for tests that
  want to assert the shape of emitted :notify / :dispatch effects).

  Returns `{:ok, new_slice, result, effects}` on success.
  """
  @spec invoke_with_effects(module(), atom(), map(), map(), map()) ::
          {:ok, map(), term() | nil, [term()]}
          | {:error, term()}
  def invoke_with_effects(behavior_module, action, slice, args, ctx) do
    handler = String.to_atom("handle_" <> Atom.to_string(action))

    enriched_ctx =
      ctx
      |> Map.put_new(:read, fn key, default -> Map.get(slice, key, default) end)

    if function_exported?(behavior_module, handler, 2) do
      case apply(behavior_module, handler, [args, enriched_ctx]) do
        {:ok, result, effects} when is_list(effects) ->
          new_slice = apply_set_effects(slice, effects)
          # Side-effect-shaped effects also need to actually run for
          # legacy assertion patterns to keep working — a test that
          # subscribes to PubSub before invoke and asserts_receive on
          # the broadcast expects the broadcast to actually happen.
          # We execute :notify (PubSub broadcast) effects here; other
          # side-effects (:dispatch, :emit, etc.) are NOT routed
          # because Router/EventLog might not be set up in unit-only
          # tests that bypassed the full dispatch path.
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

  defp apply_set_effects(slice, effects) do
    Enum.reduce(effects, slice, fn
      {:set, key, value}, acc -> Map.put(acc, key, value)
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
