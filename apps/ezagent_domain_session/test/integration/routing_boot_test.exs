defmodule EzagentDomainInstanceMessage.Integration.RoutingBootTest do
  @moduledoc """
  Boot integration — chat plugin must declare the MentionRouting
  RoutingRegistry table at app start so plugin authors / admin tooling
  can write to it.

  2026-05-25 — the sibling SessionRouting table was deleted. Its
  Feishu chat ↔ session bridge responsibility moved to the
  ExternalMirror domain's `external_mirror_bindings` table (PR-EM-3
  #317). The old "SessionRouting table is declared at chat plugin
  boot" test was removed; an additional `refute` test below now
  guards that SessionRouting is NOT (re-)introduced.
  """

  use EzagentCore.DataCase, async: false
  alias Ezagent.RoutingRegistry

  # Sandbox provided by EzagentCore.DataCase (#92).

  test "MentionRouting table is declared at chat plugin boot" do
    # list_all raises ArgumentError if not declared; reaching here
    # without raise = table exists
    assert is_list(RoutingRegistry.list_all(EzagentDomainInstanceMessage.Routing.MentionRouting))
  end

  test "SessionRouting table is NOT declared (retired 2026-05-25)" do
    # ETS table names are atoms produced via `:"ezagent_routing_..."`.
    # A whereis check is precise + does NOT raise on missing.
    assert :ets.whereis(
             :"ezagent_routing_Elixir.EzagentDomainInstanceMessage.Routing.SessionRouting"
           ) ==
             :undefined
  end

  test "DefaultRules.bootstrap is idempotent" do
    assert :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()
    assert :ok = EzagentDomainInstanceMessage.DefaultRules.bootstrap()
  end
end
