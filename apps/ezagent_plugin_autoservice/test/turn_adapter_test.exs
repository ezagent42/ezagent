defmodule EzagentPluginAutoservice.TurnAdapterTest do
  @moduledoc """
  TurnAdapter function shape tests. Full integration tests require
  a running SocialwareSession — see operator_takeover_gating_test.exs.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginAutoservice.TurnAdapter

  @session Ezagent.URI.new!("session://test/cs/adapter-test")

  test "open_turn/2 function exists" do
    assert function_exported?(TurnAdapter, :open_turn, 2)
  end

  test "compose_turn/3 function exists" do
    assert function_exported?(TurnAdapter, :compose_turn, 3)
  end

  test "settle_turn/2 function exists" do
    assert function_exported?(TurnAdapter, :settle_turn, 2)
  end

  test "claim_turn/3 function exists" do
    assert function_exported?(TurnAdapter, :claim_turn, 3)
  end

  test "cancel_turn/2 function exists" do
    assert function_exported?(TurnAdapter, :cancel_turn, 2)
  end
end
