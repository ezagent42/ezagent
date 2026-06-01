defmodule EzagentPluginCustomerChat.BootstrapTest do
  use ExUnit.Case, async: true
  alias EzagentPluginCustomerChat.Bootstrap

  test "session_uri_for builds the per-conv URI" do
    uri = Bootstrap.session_uri_for("acme", "c1")
    assert URI.to_string(uri) == "session://default/acme/c1"
  end

  test "customer_uri_for builds the synthetic user URI" do
    uri = Bootstrap.customer_uri_for("acme", "alice")
    assert URI.to_string(uri) == "entity://user/acme/customer_alice"
  end

  test "agent_name_for sanitizes and truncates conv_id" do
    assert Bootstrap.agent_name_for("t2-AbC_99") == "cust_t2_AbC_99"
    long = String.duplicate("x", 80)
    assert String.length(Bootstrap.agent_name_for(long)) == String.length("cust_") + 32
  end

  test "generate_conv_id is url-safe and unique-ish" do
    a = Bootstrap.generate_conv_id()
    b = Bootstrap.generate_conv_id()
    assert a =~ ~r/^[A-Za-z0-9_-]+$/
    assert a != b
  end

  test "customer_message builds a plain message with no synthesized mentions" do
    cust = Bootstrap.customer_uri_for("acme", "alice")
    agent = URI.parse("entity://agent/acme/cc_cust_c1")
    # The third arg is retained for the SSE controller's call site but is
    # no longer used to synthesize a mention — routing is via the explicit
    # rule installed by install_customer_routing/3.
    msg = Bootstrap.customer_message(cust, "hello", agent)
    assert msg.mentions == []
    assert msg.body.text == "hello"
    assert msg.sender == cust
  end

  test "ephemeral_template_name derives the cc.agent key from the agent_uri (keeps the cc_ flavor prefix)" do
    uri = URI.parse("entity://agent/cinnox/cc_cust_abc123")
    assert Bootstrap.ephemeral_template_name(uri) == "cc.agent.cc_cust_abc123"
  end

  test "ephemeral_template_name handles a bare entity path" do
    uri = %URI{path: "/cc_cust_x"}
    assert Bootstrap.ephemeral_template_name(uri) == "cc.agent.cc_cust_x"
  end
end

defmodule EzagentPluginCustomerChat.BootstrapRoutingTest do
  @moduledoc """
  DB-backed idempotency check for `install_customer_routing/3`. Uses the
  `EzagentCore.Repo` Ecto SQL sandbox (manual mode, set in the umbrella
  test_helper) so the `Ezagent.Routing.RuleStore.add` insert + `list`
  read run against an isolated connection. The `MentionRouting`
  RoutingRegistry table is declared at `EzagentDomainChat.Application`
  boot, so `load_into_registry/1` (called inside
  `install_customer_routing/3`) has a live table to write into.

  Non-async: shares the live RoutingRegistry ETS table and uses the
  shared-owner sandbox pattern.
  """
  use ExUnit.Case, async: false

  alias EzagentPluginCustomerChat.Bootstrap

  @table EzagentDomainChat.Routing.MentionRouting

  setup tags do
    EzagentCore.DataCase.setup_sandbox(tags)
    :ok
  end

  test "install_customer_routing is idempotent: twice adds at most one rule for the agent" do
    # Unique per run so we never collide with boot-seeded / other-test rules.
    suffix = System.unique_integer([:positive])
    session_uri = Bootstrap.session_uri_for("acme", "conv_#{suffix}")
    customer_uri = Bootstrap.customer_uri_for("acme", "alice_#{suffix}")
    agent_uri = URI.new!("entity://agent/acme/cc_cust_conv_#{suffix}")
    agent_str = URI.to_string(agent_uri)

    count_for_agent = fn ->
      @table
      |> Ezagent.Routing.RuleStore.list()
      |> Enum.count(fn r -> agent_str in (r.receivers || []) end)
    end

    assert count_for_agent.() == 0

    assert :ok = Bootstrap.install_customer_routing(session_uri, customer_uri, agent_uri)
    assert count_for_agent.() == 1

    # Second call must short-circuit on the existing-receiver check.
    assert :ok = Bootstrap.install_customer_routing(session_uri, customer_uri, agent_uri)
    assert count_for_agent.() == 1
  end
end
