defmodule EzagentPluginContent.AgentsConfigTest do
  use ExUnit.Case, async: true

  alias EzagentPluginContent.AgentsConfig

  describe "load/0" do
    test "returns {:ok, map} with fast and slow keys" do
      assert {:ok, config} = AgentsConfig.load()
      assert is_map(config)
      assert Map.has_key?(config, "fast")
      assert Map.has_key?(config, "slow")
    end

    test "fast config has expected keys (runtime, model)" do
      {:ok, config} = AgentsConfig.load()
      fast = config["fast"]
      assert is_map(fast)
      assert Map.has_key?(fast, "runtime")
      assert Map.has_key?(fast, "model")
    end

    test "slow config has expected keys (runtime, model)" do
      {:ok, config} = AgentsConfig.load()
      slow = config["slow"]
      assert is_map(slow)
      assert Map.has_key?(slow, "runtime")
      assert Map.has_key?(slow, "model")
    end
  end

  describe "for_role/1" do
    test "for_role(\"slow\") returns {:ok, map} with effort key" do
      assert {:ok, result} = AgentsConfig.for_role("slow")
      assert is_map(result)
      assert Map.has_key?(result, "effort")
    end

    test "for_role(\"fast\") returns {:ok, map} with runtime key" do
      assert {:ok, result} = AgentsConfig.for_role("fast")
      assert is_map(result)
      assert Map.has_key?(result, "runtime")
      assert result["runtime"] == "curl"
    end

    test "for_role(\"nope\") returns {:error, {:unknown_role, ...}} with known roles" do
      assert {:error, {:unknown_role, "nope", known: known}} = AgentsConfig.for_role("nope")
      assert is_list(known)
      assert "fast" in known
      assert "slow" in known
    end
  end
end
