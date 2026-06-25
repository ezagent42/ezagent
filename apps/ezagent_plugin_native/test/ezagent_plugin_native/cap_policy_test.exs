defmodule EzagentPluginNative.CapPolicyTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.Role.CapMint
  alias EzagentPluginNative.CapPolicy

  # Role-foundation RF-8 — native's CapMint cap-policy. native grants exactly
  # the recipe's `requested_caps` and NOTHING else (fail-closed default). The
  # policy is the per-recipe predicate `CapMint.mint/3` runs fail-closed.

  defp ctx do
    %{
      kind: :agent,
      instance: Ezagent.URI.agent("team-alpha", "native_demo"),
      workspace_uri: Ezagent.URI.workspace("team-alpha"),
      granter: Ezagent.URI.user("team-alpha", "alice")
    }
  end

  describe "for_recipe/1 as a CapMint policy" do
    test "GRANTS exactly the recipe's requested_caps under native" do
      recipe = [
        %{behavior: Ezagent.Behavior.Sandbox, action: :read},
        %{behavior: Ezagent.Behavior.Sandbox, action: :write}
      ]

      policy = CapPolicy.for_recipe(recipe)
      minted = CapMint.mint(recipe, ctx(), policy)

      assert length(minted) == 2
      actions = minted |> Enum.map(& &1.action) |> Enum.sort()
      assert actions == [:read, :write]
      assert Enum.all?(minted, &match?(%Capability{behavior: Ezagent.Behavior.Sandbox}, &1))
    end

    test "REJECTS an out-of-recipe cap fail-closed (not in the recipe → dropped)" do
      recipe = [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]
      policy = CapPolicy.for_recipe(recipe)

      # A cap the recipe did NOT request — same behavior, different action.
      out_of_recipe = [%{behavior: Ezagent.Behavior.Sandbox, action: :write}]
      assert [] = CapMint.mint(out_of_recipe, ctx(), policy)

      # A cap the recipe DID request still mints (proves the drop is selective).
      assert [%Capability{action: :read}] = CapMint.mint(recipe, ctx(), policy)
    end

    test "FAIL-CLOSED default: an empty recipe grants nothing" do
      policy = CapPolicy.for_recipe([])

      requested = [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]
      assert [] = CapMint.mint(requested, ctx(), policy)
    end

    test "predicate matches on {behavior, action}, not behavior alone" do
      recipe = [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]
      policy = CapPolicy.for_recipe(recipe)

      # same action different behavior → reject
      refute policy.(%{behavior: Ezagent.Behavior.ApiKeys, action: :read})
      # exact pair → grant
      assert policy.(%{behavior: Ezagent.Behavior.Sandbox, action: :read})
    end

    test "tolerates string-keyed / string-valued recipe entries (persisted recipe)" do
      recipe = [%{"behavior" => "Ezagent.Behavior.Sandbox", "action" => "read"}]
      policy = CapPolicy.for_recipe(recipe)

      # CapMint canonicalizes the needed-cap to {module, atom}; the policy must
      # match it against the string-valued recipe entry.
      assert [%Capability{behavior: Ezagent.Behavior.Sandbox, action: :read}] =
               CapMint.mint([%{behavior: Ezagent.Behavior.Sandbox, action: :read}], ctx(), policy)
    end
  end
end
