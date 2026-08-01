defmodule Ezagent.Invariants.RecredentialGenerationTest do
  @moduledoc """
  G-6/MF5 empty-allowlist recredential bypass gate.

  Public cap callers must use `Ezagent.Cap.issue/3` or `issue_for_action/3`;
  bearer callers must use the generation-stamped token stores. Any production
  call to the low-level signer/issuer outside its reviewed home is a new
  post-bump re-arm path and makes the empty violations list non-empty.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @low_level_homes MapSet.new([
                     "apps/ezagent_core/lib/ezagent/cap/authority.ex",
                     "apps/ezagent_core/lib/ezagent/cap/grant.ex"
                   ])

  test "no production site bypasses the generation-gated issuance homes" do
    violations =
      production_sources()
      |> Enum.flat_map(fn {relative, source} ->
        if MapSet.member?(@low_level_homes, relative) do
          []
        else
          low_level_calls(relative, source)
        end
      end)

    assert violations == [],
           """
           recredential-generation bypasses (empty allowlist):
           #{Enum.map_join(violations, "\n", &"  - #{&1}")}

           Route cap issuance through Ezagent.Cap.issue/3 or
           issue_for_action/3. Bearers must route through Entity.Token or the
           generation-stamped AgentBridge.TokenStore.
           """
  end

  test "the shared chokepoints contain every generation gate from the MF5 worklist" do
    cap = source("apps/ezagent_core/lib/ezagent/cap.ex")
    entity_token = source("apps/ezagent_domain_identity/lib/ezagent/entity/token.ex")

    bridge_token =
      source("apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/token_store.ex")

    entity_caps = source("apps/ezagent_domain_identity/lib/ezagent/identity_caps.ex")

    assert cap =~ "current_process_generation"
    assert cap =~ "current_generation"
    assert entity_token =~ "bound_generation"
    assert entity_token =~ "current_generation"
    assert bridge_token =~ "bound_generation"
    assert bridge_token =~ "current_generation"
    assert entity_caps =~ "verify_against_current"
  end

  test "join/baseline issuance remains routed through the public cap facade" do
    member_cap = source("apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex")
    membership = source("apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex")
    capability = source("apps/ezagent_core/lib/ezagent/capability.ex")

    assert member_cap =~ "Ezagent.Identity.Grant.issue_cap"
    assert membership =~ "Ezagent.Identity.Grant.grant_cap_via_router"
    assert capability =~ "def admin_genesis_cap"
    refute member_cap =~ "Authority.sign("
    refute membership =~ "Authority.sign("
  end

  defp low_level_calls(relative, source) do
    [
      {~r/Authority\.sign\(/, "Authority.sign"},
      {~r/Authority\.issue_current\(/, "Authority.issue_current"},
      {~r/Grant\.issue\(/, "Grant.issue"}
    ]
    |> Enum.flat_map(fn {pattern, label} ->
      if Regex.match?(pattern, source), do: ["#{relative}: #{label}"], else: []
    end)
  end

  defp production_sources do
    Path.wildcard(Path.join(@root, "apps/*/lib/**/*.ex"))
    |> Enum.map(fn path -> {Path.relative_to(path, @root), File.read!(path)} end)
  end

  defp source(relative), do: File.read!(Path.join(@root, relative))
end
