defmodule Ezagent.BehaviorRequiredCapsActionInvariantTest do
  @moduledoc """
  SPEC 2026-05-27 capability-action-axis §5 A5 — umbrella-wide property
  test: every Behavior's `required_caps/0` map MUST have its entries'
  cap-action axis equal to the map key (or `:any` for the orchestrator-
  style escape hatch).

  The contract is structural: if `required_caps/0` returns
  `%{:send => cap_struct, :receive => other_struct}`, then
  `Capability.action_of(cap_struct) == :send` (or `:any`) and
  `Capability.action_of(other_struct) == :receive` (or `:any`). Any
  drift produces silent over-grant — exactly the bug class this SPEC
  exists to close.

  This complements compile-time plugin-check 11 (which gates plugin
  modules only); this test iterates ALL loaded Behaviors umbrella-wide
  including core + domain.
  """

  use ExUnit.Case, async: true

  test "every loaded Behavior's required_caps[action] has action_of == action OR :any" do
    behaviors = discover_behaviors()

    assert behaviors != [],
           "test fixture invariant: at least one Behavior must be discoverable; got none"

    violations =
      for behavior <- behaviors,
          {action, cap} <- safely_required_caps(behavior),
          not action_matches?(cap, action) do
        {behavior, action, Ezagent.Capability.action_of(cap)}
      end

    assert violations == [],
           "Behavior.required_caps/0 action-axis violations — each entry's " <>
             "cap MUST have `action_of(cap) == map_key OR :any`. SPEC " <>
             "2026-05-27 capability-action-axis A5. Violations:\n" <>
             format_violations(violations)
  end

  defp action_matches?(%Ezagent.Capability{} = cap, action) do
    cap_action = Ezagent.Capability.action_of(cap)
    cap_action == action or cap_action == :any
  end

  # Non-struct values in required_caps are a pre-SPEC bug (plugin-check
  # check 11 enforces struct-shape). Not our concern here.
  defp action_matches?(_, _), do: true

  defp safely_required_caps(behavior) do
    if Code.ensure_loaded?(behavior) and
         function_exported?(behavior, :required_caps, 0) do
      behavior.required_caps()
    else
      %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  # Discover every loaded module implementing the `Ezagent.ActionSet`
  # behaviour. Walks `:code.all_loaded/0` and filters on the
  # `@behaviour` attribute. Same approach the no-wildcard-system-
  # principals invariant test uses to iterate the umbrella.
  defp discover_behaviors do
    :code.all_loaded()
    |> Enum.map(fn {mod, _} -> mod end)
    |> Enum.filter(&behavior_implements_ezagent_behavior?/1)
    |> Enum.uniq()
  end

  defp behavior_implements_ezagent_behavior?(mod) when is_atom(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        attrs = mod.module_info(:attributes) || []
        behaviours = Keyword.get_values(attrs, :behaviour) |> List.flatten()
        Ezagent.ActionSet in behaviours

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp format_violations(violations) do
    violations
    |> Enum.map_join("\n", fn {behavior, action, cap_action} ->
      "  - #{inspect(behavior)}.required_caps[#{inspect(action)}] " <>
        "has action_of == #{inspect(cap_action)} " <>
        "(expected #{inspect(action)} OR :any)"
    end)
  end
end
