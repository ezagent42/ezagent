defmodule EzagentCore.Test.CapOwnedBehaviorStub do
  def data_owner(%URI{} = instance), do: instance
  def data_owner(_instance), do: :no_owner
end
