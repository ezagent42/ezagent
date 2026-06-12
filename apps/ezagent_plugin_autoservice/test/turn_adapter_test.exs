defmodule EzagentPluginAutoservice.TurnAdapterTest do
  use ExUnit.Case

  alias EzagentPluginAutoservice.TurnAdapter

  # The operator's identity + caps. These tests dispatch against a session Kind
  # that is NOT running, so they assert the `%Invocation{}` is well-formed
  # (constructs without raising, valid URI) and dispatch returns
  # `{:error, :no_such_actor}` — independent of authz, which only runs once the
  # target actor exists.
  defp caller, do: Ezagent.URI.new!("entity://user/org1/opA")
  defp caps, do: MapSet.new()

  describe "open_turn/4" do
    test "dispatches with turn.open action" do
      session_uri = Ezagent.URI.new!("session://cs/org1/custA")

      input = %{
        customer_uri: Ezagent.URI.new!("entity://user/org1/custA"),
        text: "Hello, I need help"
      }

      result = TurnAdapter.open_turn(session_uri, input, caller(), caps())

      # dispatch will try to reach the session Kind; since none is running,
      # we expect either :no_such_actor or {:error, :no_such_actor}.
      # The test verifies the %Invocation{} is well-formed (no raises on
      # construction, valid URI).
      assert result == {:error, :no_such_actor}
    end
  end

  describe "compose_turn/5" do
    test "dispatches with turn.compose action and result_refs" do
      session_uri = Ezagent.URI.new!("session://cs/org1/custA")

      input = %{
        agent_uri: Ezagent.URI.new!("entity://agent/org1/curl_fast-custA"),
        text: "Sure, let me look into that."
      }

      result = TurnAdapter.compose_turn(session_uri, "turn-001", input, caller(), caps())

      assert result == {:error, :no_such_actor}
    end
  end

  describe "settle_turn/4" do
    test "dispatches with turn.settle action" do
      session_uri = Ezagent.URI.new!("session://cs/org1/custA")

      result = TurnAdapter.settle_turn(session_uri, "turn-001", caller(), caps())

      assert result == {:error, :no_such_actor}
    end
  end

  describe "claim_turn/5" do
    test "dispatches with turn.claim action and by field" do
      session_uri = Ezagent.URI.new!("session://cs/org1/custA")

      input = %{
        operator_uri: Ezagent.URI.new!("entity://user/org1/opA")
      }

      result = TurnAdapter.claim_turn(session_uri, "turn-001", input, caller(), caps())

      assert result == {:error, :no_such_actor}
    end
  end
end
