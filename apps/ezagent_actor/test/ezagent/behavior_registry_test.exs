defmodule Ezagent.BehaviorRegistryTest do
  use ExUnit.Case
  alias Ezagent.BehaviorRegistry

  # Use unique fake-module atoms per test so we don't trip on shared state.
  defp fake(suffix),
    do: Module.concat([__MODULE__, "Fake#{suffix}#{System.unique_integer([:positive])}"])

  test "register + lookup round-trip" do
    kind = fake("K")
    action = :do_thing
    behavior = fake("B")

    :ok = BehaviorRegistry.register(kind, action, behavior)
    assert {:ok, ^behavior} = BehaviorRegistry.lookup(kind, action)
  end

  test "lookup returns :error for unknown (kind, action)" do
    assert :error = BehaviorRegistry.lookup(fake("Unknown"), :nope)
  end

  test "re-register overwrites" do
    kind = fake("K")
    action = :ax
    b1 = fake("B1")
    b2 = fake("B2")

    :ok = BehaviorRegistry.register(kind, action, b1)
    :ok = BehaviorRegistry.register(kind, action, b2)
    assert {:ok, ^b2} = BehaviorRegistry.lookup(kind, action)
  end

  test "list_all includes our registration" do
    kind = fake("K")
    action = :listed
    behavior = fake("B")

    :ok = BehaviorRegistry.register(kind, action, behavior)

    entries = BehaviorRegistry.list_all()
    assert Enum.any?(entries, fn {{k, a}, b} -> k == kind and a == action and b == behavior end)
  end
end
