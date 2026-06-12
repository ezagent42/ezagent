defmodule Ezagent.Behavior.KindBaseTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.KindBase

  test "state_slice is :kind_base" do
    assert KindBase.state_slice() == :kind_base
  end

  test "create/1 captures the instance behavior set from a PRESENT :behaviors arg" do
    behaviors = [Ezagent.Behavior.Session, Ezagent.Behavior.Surface]
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
    {:ok, st} = KindBase.create(%{behaviors: [Ezagent.Behavior.Session]})
    slice = %{state: st, transients: %{}}
    assert KindBase.behaviors_in_slice(slice) == [Ezagent.Behavior.Session]
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

  describe "snapshot round-trip" do
    setup do
      Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    end

    test "kind_base slice survives load_or_init after save_now" do
      uri =
        Ezagent.URI.session(:system, :default, :"kbtest-#{System.unique_integer([:positive])}")

      behaviors = [Ezagent.Behavior.Session, Ezagent.Behavior.Surface]

      # A throwaway Kind module composing only KindBase, on_change persistence.
      defmodule KBTestKind do
        @behaviour Ezagent.Kind
        @impl true
        def type_name, do: :session
        @impl true
        def behaviors, do: [Ezagent.Behavior.KindBase]
        @impl true
        def persistence, do: {:snapshot, :on_change}
        @impl true
        def supervisor, do: Ezagent.Kind.Server
      end

      fresh = Ezagent.Kind.Snapshot.load_or_init(uri, KBTestKind, %{behaviors: behaviors})
      :ok = Ezagent.Kind.Snapshot.save_now(uri, KBTestKind, fresh)

      # The persisted snapshot wins on reload; the args here are the unused
      # cold-init fallback (a snapshot already exists for this uri).
      reloaded = Ezagent.Kind.Snapshot.load_or_init(uri, KBTestKind, %{behaviors: behaviors})
      assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == behaviors
    end
  end
end
