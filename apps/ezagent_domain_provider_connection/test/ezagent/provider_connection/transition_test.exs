defmodule Ezagent.ProviderConnection.TransitionTest do
  use ExUnit.Case, async: true
  alias Ezagent.ProviderConnection.Transition

  test "terminal states cannot reactivate" do
    assert Transition.allowed?(:pending_authorization, :active)
    assert Transition.allowed?(:active, :revoking)
    assert Transition.allowed?(:revoking, :revoked)
    refute Transition.allowed?(:revoked, :active)
    refute Transition.allowed?(:disconnected, :pending_authorization)
  end
end
