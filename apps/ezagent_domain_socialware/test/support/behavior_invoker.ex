defmodule EzagentDomainSocialware.Test.BehaviorInvoker do
  @moduledoc """
  Test helper for direct Lifecycle handler tests.

  It invokes `handle_<action>/2`, enriches the context with a flat state
  reader, and folds state effects back into the supplied slice.
  """

  @spec invoke_with_effects(module(), atom(), map(), map(), map()) ::
          {:ok, map(), term(), [term()]} | {:error, term()}
  def invoke_with_effects(behavior_module, action, slice, args, ctx) do
    handler = String.to_atom("handle_" <> Atom.to_string(action))

    enriched_ctx =
      ctx
      |> Map.put_new(:read, fn key, default -> Map.get(slice, key, default) end)
      |> Map.put_new(:state, slice)
      |> Map.put_new(:transients, %{})

    case apply(behavior_module, handler, [args, enriched_ctx]) do
      {:ok, result, effects} when is_list(effects) ->
        {:ok, apply_set_effects(slice, effects), result, effects}

      {:ok, result} ->
        {:ok, slice, result, []}

      {:error, _reason} = err ->
        err

      other ->
        {:error, {:bad_handler_return, behavior_module, action, other}}
    end
  end

  defp apply_set_effects(slice, effects) do
    Enum.reduce(effects, slice, fn
      {:set, key, value}, acc -> Map.put(acc, key, value)
      {:set_transient, _key, _value}, acc -> acc
      _other, acc -> acc
    end)
  end
end
