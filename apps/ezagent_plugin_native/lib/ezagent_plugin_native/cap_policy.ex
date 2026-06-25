defmodule EzagentPluginNative.CapPolicy do
  @moduledoc """
  CapMint cap-policy for the `native` flavor (role-foundation RF-8).

  The `native` flavor is the generic, no-engine/no-sidecar host for role
  agents (kanban-manager and friends). It declares NOTHING role-specific —
  the ROLE supplies behaviors AND requests caps per-instance via its recipe
  (RF-5a). So native's cap policy is the simplest fail-closed one that is
  still meaningful: **grant exactly the caps the recipe asked for, nothing
  else.**

  ## What this is

  `Ezagent.Role.CapMint.mint/3` takes an INJECTED policy predicate — a
  `(needed_cap_map -> boolean())` it runs fail-closed (kept ONLY on a strict
  `true`; a non-`true` return OR a raise drops the cap). CapMint is the
  flavor-neutral minting MECHANISM; the per-flavor POLICY is data passed in.
  This module is the `native` flavor's policy. It lives in the plugin, not in
  core — a flavor is a plugin, and core must not name a flavor.

  ## Fail-closed default (stated)

  `for_recipe/1` closes over the recipe's `requested_caps` — the authorized
  `{behavior, action}` cap-templates already validated by `Ezagent.Role.new/1`.
  The returned predicate returns `true` for a needed-cap whose
  `{behavior, action}` is one of those recipe pairs, and **`false` for
  everything else**. There is no implicit grant: a cap the recipe did not
  request is rejected, and an empty recipe grants nothing. The recipe is the
  whole allow-list.

  Caps are still `{behavior, action}` cap-templates (Role.new rejects a recipe
  carrying materialization axes — `kind`/`instance`/`workspace_uri`/
  `granted_by` — so a native role cannot smuggle a concrete/foreign scope in).
  CapMint injects those axes; this policy only adjudicates the
  `{behavior, action}` pair.

  ## Why a closure and not `fn _ -> true end`

  In the steady RF-5a flow the SAME recipe feeds both halves —
  `CapMint.mint(recipe.requested_caps, ctx, for_recipe(recipe.requested_caps))`
  — and `mint/3` only ever iterates `recipe.requested_caps`, so the predicate
  is always-true there ("nothing else" is structural to CapMint, which never
  invents a cap). The recipe-closed predicate earns its keep as DEFENSE-IN-DEPTH:
  if any caller ever passes `mint/3` a SUPERSET of the recipe, the out-of-recipe
  caps are dropped fail-closed instead of granted. That divergent-input case is
  exactly what the rejection test exercises; `fn _ -> true end` would lose both
  the property and its testability.

  ## How it is selected

  Declared on the `native` `agent_flavor_decl` as `:cap_policy`
  (`&EzagentPluginNative.CapPolicy.for_recipe/1`). RF-5a's create wiring reads
  the flavor's `:cap_policy` from `Ezagent.AgentFlavorRegistry`, builds the
  per-recipe predicate, and passes it to `CapMint.mint/3` at
  `Ezagent.Workspace.grant_initial_caps`. This module never calls CapMint
  itself — it is pure policy data.
  """

  @doc """
  Build the `native` per-recipe fail-closed CapMint policy predicate.

  `requested_caps` are the recipe's authorized cap-templates (atom-keyed
  `%{behavior:, action:}` after `Ezagent.Role.new/1`). Returns a
  `(needed_cap_map -> boolean())` that grants a needed-cap iff its
  `{behavior, action}` matches one the recipe requested; everything else is
  rejected (fail-closed default). String-keyed / string-valued recipe entries
  are tolerated (canonicalized to `{module, atom}` for comparison) so a
  persisted (JSON/snapshot) recipe round-trips identically.
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

  # Canonicalize a cap map's {behavior, action} into a comparable
  # {module, atom} pair, atom/string-key + atom/string-value tolerant.
  # An unresolvable value yields nil → never matches (fail-closed).
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
