defmodule Ezagent.Role.CapMintTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.Role.CapMint

  # Task #54 §2.3.1 — the fail-closed cap authorization + minting, done WITH the
  # full agent materialization context (kind/instance/workspace/granter) that a
  # context-free composer cannot supply. A role's REQUESTED caps are intersected
  # with the flavor/tenant policy (fail-closed), then minted into canonical
  # %Capability{} via Capability.normalize!/2. A rejected/un-mintable cap is
  # dropped — never copied.

  defp ctx do
    %{
      kind: :agent,
      instance: Ezagent.URI.agent("team-alpha", "cc_demo"),
      workspace_uri: Ezagent.URI.workspace("team-alpha"),
      granter: Ezagent.URI.user("team-alpha", "alice")
    }
  end

  describe "mint/3" do
    test "mints a permitted requested cap into a concrete %Capability{} (all axes from context)" do
      c = ctx()
      requested = [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]

      assert [%Capability{} = cap] = CapMint.mint(requested, c, fn _ -> true end)
      assert cap.kind == :agent
      assert cap.behavior == Ezagent.Behavior.Sandbox
      assert cap.action == :read
      assert URI.to_string(cap.instance) == URI.to_string(c.instance)
      assert URI.to_string(cap.workspace_uri) == URI.to_string(c.workspace_uri)
      assert URI.to_string(cap.granted_by) == URI.to_string(c.granter)
    end

    test "FAIL-CLOSED §6 negative-authz: a cap the policy rejects is NOT minted (never copied)" do
      # both caps are well-formed (real Behavior + atom action) so the POLICY is
      # what differentiates — permits :read, rejects :write
      requested = [
        %{behavior: Ezagent.Behavior.Sandbox, action: :read},
        %{behavior: Ezagent.Behavior.Sandbox, action: :write}
      ]

      minted = CapMint.mint(requested, ctx(), fn %{action: a} -> a == :read end)

      assert [%Capability{action: :read}] = minted
      refute Enum.any?(minted, &(&1.action == :write))
    end

    test "canonicalizes a string-valued behavior to its module before minting" do
      requested = [%{behavior: "Ezagent.Behavior.Sandbox", action: "read"}]

      assert [%Capability{behavior: Ezagent.Behavior.Sandbox, action: :read}] =
               CapMint.mint(requested, ctx(), fn _ -> true end)
    end

    test "FAIL-CLOSED (no crash) when the policy predicate RAISES" do
      requested = [%{behavior: Ezagent.Behavior.Sandbox, action: :read}]
      assert [] = CapMint.mint(requested, ctx(), fn _ -> raise "boom" end)
    end

    test "FAIL-CLOSED independent of policy: an unresolvable value is dropped even under a permissive policy" do
      # behavior "No.Such.Module" can't canonicalize → stays a string → dropped
      # by well_formed? BEFORE authorization, so even an always-true policy can
      # NOT mint it (no phantom atom, no string-valued %Capability{}).
      requested = [%{behavior: "No.Such.Module", action: "read"}]
      assert [] = CapMint.mint(requested, ctx(), fn _ -> true end)

      # a non-Behavior atom is likewise dropped (must be a real Behavior module)
      assert [] =
               CapMint.mint([%{behavior: :not_a_behavior, action: :read}], ctx(), fn _ -> true end)
    end
  end
end
