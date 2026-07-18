defmodule Ezagent.Agent.ErrorSignalTest do
  use ExUnit.Case, async: true

  alias Ezagent.Agent.ErrorSignal

  describe "encode/1" do
    test "atom reason" do
      assert ErrorSignal.encode(:sdk_sidecar_timeout) == %{"reason" => ["sdk_sidecar_timeout"]}
    end

    test "atom-headed tuple reason keeps JSON-safe args as-is" do
      assert ErrorSignal.encode({:no_api_key, "anthropic"}) ==
               %{"reason" => ["no_api_key", "anthropic"]}

      assert ErrorSignal.encode({:http, 502, "bad gateway"}) ==
               %{"reason" => ["http", 502, "bad gateway"]}
    end

    test "atom args are stringified" do
      assert ErrorSignal.encode({:transport, :timeout}) ==
               %{"reason" => ["transport", "timeout"]}
    end

    test "non-JSON-safe args are inspected and truncated" do
      %{"reason" => ["http", 500, body]} = ErrorSignal.encode({:http, 500, %{a: 1}})
      assert body == inspect(%{a: 1})

      long = String.duplicate("x", 2_000)
      %{"reason" => ["transport", encoded]} = ErrorSignal.encode({:transport, long})
      assert String.length(encoded) <= 501
      assert String.ends_with?(encoded, "…")
    end

    test "invalid UTF-8 binary args become valid strings" do
      %{"reason" => ["decode", arg]} = ErrorSignal.encode({:decode, <<0xFF, 0xFE>>})
      assert String.valid?(arg)
    end

    test "non-atom-headed reasons fall back to the agent_error tag" do
      assert %{"reason" => ["agent_error", _]} = ErrorSignal.encode(%{weird: true})
      assert %{"reason" => ["agent_error", _]} = ErrorSignal.encode({"str_head", 1})
    end
  end

  describe "decode/1" do
    test "round-trips atom reasons" do
      assert {:ok, :not_alive} = ErrorSignal.decode(ErrorSignal.encode(:not_alive))
    end

    test "round-trips atom-headed tuples (tag restored as atom, args as decoded)" do
      assert {:ok, {:no_api_key, "deepseek"}} =
               ErrorSignal.decode(ErrorSignal.encode({:no_api_key, "deepseek"}))

      assert {:ok, {:http, 502, "bad gateway"}} =
               ErrorSignal.decode(ErrorSignal.encode({:http, 502, "bad gateway"}))
    end

    test "never mints atoms — unknown tag returns :error" do
      assert :error =
               ErrorSignal.decode(%{"reason" => ["surely_not_an_existing_atom_g5_x9z"]})
    end

    test "malformed payloads return :error" do
      assert :error = ErrorSignal.decode(%{"reason" => []})
      assert :error = ErrorSignal.decode(%{"reason" => "no_api_key"})
      assert :error = ErrorSignal.decode(%{})
      assert :error = ErrorSignal.decode(nil)
      assert :error = ErrorSignal.decode("boom")
    end
  end

  describe "fallback_text/1" do
    test "uses the reason tag, uniform shape" do
      assert ErrorSignal.fallback_text({:no_api_key, "deepseek"}) == "[agent error] no_api_key"
      assert ErrorSignal.fallback_text(:not_alive) == "[agent error] not_alive"
      assert ErrorSignal.fallback_text(%{weird: true}) == "[agent error] agent_error"
    end
  end

  describe "reply_body/1" do
    test "carries fallback text + encoded payload + empty attachments" do
      assert %{
               text: "[agent error] no_api_key",
               error: %{"reason" => ["no_api_key", "deepseek"]},
               attachments: []
             } = ErrorSignal.reply_body({:no_api_key, "deepseek"})
    end
  end
end
