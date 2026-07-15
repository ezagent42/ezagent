defmodule Ezagent.Email.Inbound.PrincipalInvariantTest do
  use ExUnit.Case, async: true

  @principal Path.expand("../lib/ezagent/email/inbound/principal.ex", __DIR__)

  test "inbound authority is issued at the Cap chokepoint and never hand-stamped" do
    source = File.read!(@principal)

    assert source =~ "Ezagent.Cap.issue"
    assert source =~ "{:rule, :verified_email_binding, binding_actor}"
    refute source =~ "%Ezagent.Capability{"
    refute source =~ "granted_by:"
    refute source =~ "granted_at:"
  end
end
