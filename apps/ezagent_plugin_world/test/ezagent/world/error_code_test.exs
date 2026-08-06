defmodule Ezagent.World.ErrorCodeTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.ErrorCode

  describe "all/0" do
    test "returns at least 2 registered codes" do
      codes = ErrorCode.all()
      assert length(codes) >= 2
    end

    test "each entry has required fields" do
      for code <- ErrorCode.all() do
        assert is_binary(code.code)
        assert is_tuple(code.trigger)
        assert is_atom(code.category)
        assert is_map(code.message)
        assert is_binary(code.message.what)
        assert is_binary(code.message.impact)
      end
    end

    test "#1 agent_credential_missing has correct trigger" do
      code = ErrorCode.lookup("agent_credential_missing")
      assert code != nil
      assert code.trigger == {:error, {:no_api_key, :_}}
      assert code.category == :credential
    end

    test "#3 action_unauthorized has correct trigger" do
      code = ErrorCode.lookup("action_unauthorized")
      assert code != nil
      assert code.trigger == {:error, :unauthorized}
      assert code.category == :permission
    end

    test "generation_timeout clearly describes a model timeout" do
      code = ErrorCode.lookup("agent_generation_timeout")

      assert code.trigger == {:error, :generation_timeout}
      assert code.category == :availability
      assert code.message.what =~ "超时"
      assert code.message.impact =~ "重新发送"
    end
  end

  describe "lookup/1" do
    test "returns nil for unknown code" do
      assert ErrorCode.lookup("nonexistent") == nil
    end
  end
end
