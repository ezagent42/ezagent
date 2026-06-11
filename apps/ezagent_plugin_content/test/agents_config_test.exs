defmodule EzagentPluginContent.AgentsConfigTest do
  use ExUnit.Case, async: true

  alias EzagentPluginContent.AgentsConfig

  describe "load/0" do
    test "returns a map with fast and slow keys" do
      config = AgentsConfig.load()
      assert is_map(config)
      assert Map.has_key?(config, "fast")
      assert Map.has_key?(config, "slow")
    end

    test "fast config has expected keys (runtime, model)" do
      fast = AgentsConfig.load()["fast"]
      assert is_map(fast)
      assert Map.has_key?(fast, "runtime")
      assert Map.has_key?(fast, "model")
    end

    test "slow config has expected keys (runtime, model)" do
      slow = AgentsConfig.load()["slow"]
      assert is_map(slow)
      assert Map.has_key?(slow, "runtime")
      assert Map.has_key?(slow, "model")
    end
  end

  describe "for_role/1" do
    test "for_role(\"slow\") returns map with effort key" do
      result = AgentsConfig.for_role("slow")
      assert is_map(result)
      assert Map.has_key?(result, "effort")
    end

    test "for_role(\"fast\") returns map with runtime key" do
      result = AgentsConfig.for_role("fast")
      assert is_map(result)
      assert Map.has_key?(result, "runtime")
      assert result["runtime"] == "curl"
    end

    test "for_role(\"nope\") raises ArgumentError with known roles" do
      assert_raise ArgumentError, ~r/known roles/, fn ->
        AgentsConfig.for_role("nope")
      end
    end
  end
end
