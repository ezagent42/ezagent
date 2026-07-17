defmodule Ezagent.World.ErrorMatcherTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.ErrorMatcher

  describe "match/1 — both codes through same matcher" do
    test "matches #1 agent_credential_missing (tuple trigger with wildcard)" do
      result = ErrorMatcher.match({:error, {:no_api_key, "anthropic"}})
      assert result != nil
      assert result.code == "agent_credential_missing"
    end

    test "matches #1 with different provider" do
      result = ErrorMatcher.match({:error, {:no_api_key, "openai"}})
      assert result != nil
      assert result.code == "agent_credential_missing"
    end

    test "matches #3 action_unauthorized (atom trigger)" do
      result = ErrorMatcher.match({:error, :unauthorized})
      assert result != nil
      assert result.code == "action_unauthorized"
    end

    test "returns nil for unregistered error" do
      assert ErrorMatcher.match({:error, :some_unregistered_error}) == nil
    end

    test "returns nil for non-error input" do
      assert ErrorMatcher.match(:ok) == nil
      assert ErrorMatcher.match({:ok, "result"}) == nil
    end
  end
end
