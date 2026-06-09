defmodule Ezagent.Behavior.KindBaseTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.KindBase

  test "state_slice is :kind_base" do
    assert KindBase.state_slice() == :kind_base
  end

  test "create/1 captures the instance behavior set from a PRESENT :behaviors arg" do
    behaviors = [Ezagent.Behavior.Chat, Ezagent.Behavior.Surface]
    assert {:ok, %{behaviors: ^behaviors}} = KindBase.create(%{behaviors: behaviors})
  end

  test "create/1 with NO :behaviors arg yields the legacy sentinel nil (NOT [])" do
    # ABSENT key → legacy static Kind → sentinel nil, so effective_set later
    # expands to the FULL declared list. It must NOT be persisted as [] (which
    # is a PRESENT empty list = base-behaviors-only).
    assert {:ok, %{behaviors: nil}} = KindBase.create(%{})
  end

  test "create/1 with an EXPLICIT empty list persists [] (distinct from the absent/nil case)" do
    # PRESENT empty list → the instance deliberately carries ONLY base behaviors.
    # This MUST be distinguishable from the absent case above (codex CRITICAL).
    assert {:ok, %{behaviors: []}} = KindBase.create(%{behaviors: []})
  end

  test "behaviors_in_slice/1 reads the captured PRESENT set from a two-container slice" do
    {:ok, st} = KindBase.create(%{behaviors: [Ezagent.Behavior.Chat]})
    slice = %{state: st, transients: %{}}
    assert KindBase.behaviors_in_slice(slice) == [Ezagent.Behavior.Chat]
  end

  test "behaviors_in_slice/1 reads back the EXPLICIT empty list as [] (present, not sentinel)" do
    {:ok, st} = KindBase.create(%{behaviors: []})
    slice = %{state: st, transients: %{}}
    assert KindBase.behaviors_in_slice(slice) == []
  end

  test "behaviors_in_slice/1 returns the legacy sentinel nil for the absent-args slice and missing slices" do
    # The legacy sentinel survives the round-trip: an absent-args Kind reads
    # back nil so effective_set falls back to the declared list.
    {:ok, st} = KindBase.create(%{})
    assert KindBase.behaviors_in_slice(%{state: st, transients: %{}}) == nil
    assert KindBase.behaviors_in_slice(nil) == nil
    assert KindBase.behaviors_in_slice(%{state: %{}, transients: %{}}) == nil
  end
end
