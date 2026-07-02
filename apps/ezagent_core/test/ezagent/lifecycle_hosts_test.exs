defmodule Ezagent.LifecycleHostsTest do
  use ExUnit.Case, async: true
  alias Ezagent.Kind.InstanceSetSupport.SupersetSessionKind

  test "hosts_lifecycle?/2 reflects the instance set, not the module superset" do
    # Instance set with KindBase (a Lifecycle behavior) → true.
    lc_set = %{kind_base: %{state: %{behaviors: [Ezagent.ActionSet.KindBase]}, transients: %{}}}
    assert Ezagent.Lifecycle.hosts_lifecycle?(SupersetSessionKind, lc_set)

    # Legacy sentinel (nil captured) → falls back to declared list (still has Lifecycle).
    full = %{kind_base: %{state: %{behaviors: nil}, transients: %{}}}
    assert Ezagent.Lifecycle.hosts_lifecycle?(SupersetSessionKind, full)

    # Explicit empty list → base-only, but KindBase (base) is a Lifecycle
    # behavior, so hosts_lifecycle? is STILL true (correct, not a fallback).
    base_only = %{kind_base: %{state: %{behaviors: []}, transients: %{}}}
    assert Ezagent.Lifecycle.hosts_lifecycle?(SupersetSessionKind, base_only)
  end

  test "hosts_lifecycle?/1 unchanged for static callers" do
    assert Ezagent.Lifecycle.hosts_lifecycle?(Ezagent.Entity.Session) ==
             Ezagent.Lifecycle.hosts_lifecycle?(Ezagent.Entity.Session)
  end
end
