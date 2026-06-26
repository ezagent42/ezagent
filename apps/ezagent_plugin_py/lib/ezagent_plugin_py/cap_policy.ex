defmodule EzagentPluginPy.CapPolicy do
  @moduledoc """
  CapMint cap-policy for the `py` flavor (role-foundation RF-8; py-agent P4).

  The `py` flavor is the general script-driven Python host. A py-ROLE (e.g.
  `np`) is `py` flavor + an operator script + a set of requested caps. RF-5a's
  create wiring reads this flavor's `:cap_policy` from
  `Ezagent.AgentFlavorRegistry` and passes
  `cap_policy.(recipe.requested_caps)` to `Ezagent.Role.CapMint.mint/3` when a
  py-agent is created WITH a role.

  Same fail-closed shape as `EzagentPluginNative.CapPolicy`: **grant exactly the
  caps the recipe asked for, nothing else.** The recipe is the whole allow-list;
  a cap the recipe did not request is rejected; an empty recipe grants nothing.
  See that module's moduledoc for the why-a-closure rationale — this is the
  identical mechanism specialized to py.
  """

  @doc """
  Build the `py` per-recipe fail-closed CapMint policy predicate.

  `requested_caps` are the role recipe's authorized cap-templates (atom-keyed
  `%{behavior:, action:}` after `Ezagent.Role.new/1`). Returns a
  `(needed_cap_map -> boolean())` that grants a needed-cap iff its
  `{behavior, action}` matches one the recipe requested; everything else is
  rejected (fail-closed default).
  """
  @spec for_recipe([map()]) :: (map() -> boolean())
  def for_recipe(requested_caps) when is_list(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(&pair/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    fn needed -> MapSet.member?(allowed, pair(needed)) end
  end

  defp pair(cap) when is_map(cap) do
    behavior = canon_module(axis(cap, :behavior))
    action = canon_atom(axis(cap, :action))

    if is_atom(behavior) and not is_nil(behavior) and is_atom(action) and not is_nil(action) do
      {behavior, action}
    end
  end

  defp pair(_), do: nil

  defp axis(cap, key), do: Map.get(cap, key) || Map.get(cap, Atom.to_string(key))

  defp canon_module(s) when is_binary(s) do
    String.to_existing_atom(if String.starts_with?(s, "Elixir."), do: s, else: "Elixir." <> s)
  rescue
    ArgumentError -> nil
  end

  defp canon_module(v) when is_atom(v), do: v
  defp canon_module(_), do: nil

  defp canon_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp canon_atom(v) when is_atom(v), do: v
  defp canon_atom(_), do: nil
end
