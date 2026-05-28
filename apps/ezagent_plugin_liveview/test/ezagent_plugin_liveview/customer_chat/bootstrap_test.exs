defmodule EzagentPluginLiveview.CustomerChat.BootstrapTest do
  use ExUnit.Case, async: true
  alias EzagentPluginLiveview.CustomerChat.Bootstrap

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
    assert String.length(Bootstrap.agent_name_for(long)) <= length('cust_') + 32
  end

  test "generate_conv_id is url-safe and unique-ish" do
    a = Bootstrap.generate_conv_id()
    b = Bootstrap.generate_conv_id()
    assert a =~ ~r/^[A-Za-z0-9_-]+$/
    assert a != b
  end

  test "customer_message tags mention of the cc agent" do
    cust = Bootstrap.customer_uri_for("acme", "alice")
    agent = URI.parse("entity://agent/acme/cc_cust_c1")
    msg = Bootstrap.customer_message(cust, "hello", agent)
    assert msg.mentions == [agent]
    assert msg.body.text == "hello"
  end
end
