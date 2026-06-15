defmodule EzagentPluginAutoservice.TurnAdapterTest do
  @moduledoc "TurnAdapter module existence and basic shape tests."
  use ExUnit.Case, async: true

  test "TurnAdapter module is defined" do
    assert Code.ensure_loaded?(EzagentPluginAutoservice.TurnAdapter)
  end

  test "cancel_turn/2 exists" do
    assert {:cancel_turn, 2} in EzagentPluginAutoservice.TurnAdapter.__info__(:functions)
  end

  test "all lifecycle functions present" do
    funs = EzagentPluginAutoservice.TurnAdapter.__info__(:functions)
    assert {:open_turn, 2} in funs
    assert {:compose_turn, 3} in funs
    assert {:settle_turn, 2} in funs
    assert {:claim_turn, 3} in funs
    assert {:cancel_turn, 2} in funs
  end
end
