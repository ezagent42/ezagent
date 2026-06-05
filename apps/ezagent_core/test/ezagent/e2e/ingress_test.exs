defmodule Ezagent.E2E.IngressTest do
  use ExUnit.Case, async: true
  alias Ezagent.E2E.Ingress

  defmodule StubDispatcher do
    def dispatch(opts), do: {:dispatched, opts}
  end

  test "feishu/1 late-binds to the injected dispatcher and passes opts (minus :dispatcher)" do
    assert {:dispatched, opts} =
             Ingress.feishu(
               chat_id: "oc_x",
               sender: %{"open_id" => "ou_1"},
               text: "@传话游戏 苹果",
               dispatcher: StubDispatcher
             )

    assert opts[:chat_id] == "oc_x"
    assert opts[:text] == "@传话游戏 苹果"
    assert opts[:sender] == %{"open_id" => "ou_1"}
    refute Keyword.has_key?(opts, :dispatcher)
  end

  test "feishu/1 → clear error when the dispatcher module is not loaded" do
    assert {:error, {:inbound_dispatcher_unavailable, :"Elixir.NoSuchInboundDispatcher"}} =
             Ingress.feishu(chat_id: "oc_x", sender: %{}, dispatcher: :"Elixir.NoSuchInboundDispatcher")
  end
end
