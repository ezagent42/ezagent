defmodule EzagentPluginLiveview.CustomerChat.ComponentsTest do
  use ExUnit.Case, async: true
  alias EzagentPluginLiveview.CustomerChat.Components

  test "message_to_row classifies a customer message as :customer" do
    msg = Ezagent.Message.new(URI.parse("entity://user/acme/customer_alice"), %{text: "hi"})
    row = Components.message_to_row(msg, "entity://user/acme/customer_alice")
    assert row.kind == :customer
    assert row.text == "hi"
  end

  test "message_to_row classifies the cc agent as :agent" do
    msg = Ezagent.Message.new(URI.parse("entity://agent/acme/cc_cust_c1"), %{text: "hello"})
    row = Components.message_to_row(msg, "entity://user/acme/customer_alice")
    assert row.kind == :agent
  end

  test "message_to_row classifies a different user (operator) as :operator" do
    msg = Ezagent.Message.new(URI.parse("entity://user/acme/jane"), %{text: "I'm a human"})
    row = Components.message_to_row(msg, "entity://user/acme/customer_alice")
    assert row.kind == :operator
  end

  test "message_to_row flags the takeover notice" do
    msg = Ezagent.Message.new(URI.parse("entity://user/system/chat-router"), %{text: "(客服已接管对话)"})
    msg = %{msg | body: Map.put(msg.body, :is_takeover_notice, true)}
    row = Components.message_to_row(msg, "entity://user/acme/customer_alice")
    assert row.notice? == true
  end
end
