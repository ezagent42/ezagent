defmodule Ezagent.Kind.BehaviorSetTest do
  use ExUnit.Case, async: true

  alias Ezagent.Kind.BehaviorSet

  defmodule SupersetKind do
    @behaviour Ezagent.Kind
    @impl true
    def type_name, do: :session
    @impl true
    def behaviors, do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Surface, Ezagent.Behavior.KindBase]
    @impl true
    def persistence, do: :ephemeral
    @impl true
    def supervisor, do: Ezagent.Kind.Server
  end

  test "LEGACY sentinel (nil captured) → full declared list + base behaviors (static-Kind preservation)" do
    # ABSENT-args instance: KindBase persisted the sentinel nil.
    slice_state = %{kind_base: %{state: %{behaviors: nil}, transients: %{}}}

    # Sentinel nil → every declared behavior stays, in declaration order, then
    # the always-on base behaviors (Manage from UniversalBehaviors; KindBase
    # already declared so deduped).
    assert BehaviorSet.effective_set(SupersetKind, slice_state) ==
             Ezagent.Kind.behaviors_of(SupersetKind) ++ [Ezagent.Behavior.Manage]
  end

  test "EXPLICIT empty captured list ([]) → base behaviors ONLY, NOT the declared superset (codex CRITICAL)" do
    # A PRESENT empty list is NOT the legacy sentinel: it intersects to nothing
    # declared, so the effective set is exactly base_behaviors — Chat/Surface
    # (declared) must be absent.
    slice_state = %{kind_base: %{state: %{behaviors: []}, transients: %{}}}

    assert BehaviorSet.effective_set(SupersetKind, slice_state) == BehaviorSet.base_behaviors()
    refute Ezagent.Behavior.Chat in BehaviorSet.effective_set(SupersetKind, slice_state)
    refute Ezagent.Behavior.Surface in BehaviorSet.effective_set(SupersetKind, slice_state)
    assert Ezagent.Behavior.KindBase in BehaviorSet.effective_set(SupersetKind, slice_state)
    assert Ezagent.Behavior.Manage in BehaviorSet.effective_set(SupersetKind, slice_state)
  end

  test "captured subset → (declared ∩ captured) + base behaviors, declaration order preserved" do
    captured = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

    # Surface is dropped (out of captured set); Chat + KindBase kept in
    # declaration order; Manage appended as a universal base behavior.
    assert BehaviorSet.effective_set(SupersetKind, slice_state) ==
             [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase, Ezagent.Behavior.Manage]

    refute Ezagent.Behavior.Surface in BehaviorSet.effective_set(SupersetKind, slice_state)
  end

  test "member?/2 reflects the effective set" do
    captured = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

    assert BehaviorSet.member?(Ezagent.Behavior.Chat, BehaviorSet.effective_set(SupersetKind, slice_state))
    refute BehaviorSet.member?(Ezagent.Behavior.Surface, BehaviorSet.effective_set(SupersetKind, slice_state))
  end

  describe "init_set/2 (first-spawn scoping, BEFORE any slice exists)" do
    test "args :behaviors subset → declared ∩ subset, PLUS the base behaviors" do
      # A chat-only spawn on the superset Kind. init_set is what
      # `init_fresh_first_spawn` enumerates on FIRST spawn (no :kind_base slice
      # yet), so Surface's
      # create/init_slice must NEVER appear here.
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: [Ezagent.Behavior.Chat]})

      assert Ezagent.Behavior.Chat in set
      # base behaviors are always present so KindBase can persist the set and
      # Manage stays reachable (universal-by-construction).
      assert Ezagent.Behavior.KindBase in set
      assert Ezagent.Behavior.Manage in set
      # out-of-set declared behavior is EXCLUDED — its create/init_slice must
      # not run on first spawn.
      refute Ezagent.Behavior.Surface in set
    end

    test "ABSENT :behaviors arg → full declared list, PLUS base behaviors (legacy static-Kind preservation)" do
      # No :behaviors KEY at all → legacy path → full declared list.
      set = BehaviorSet.init_set(SupersetKind, %{})
      declared = Ezagent.Kind.behaviors_of(SupersetKind)

      assert Enum.all?(declared, &(&1 in set))
      assert Ezagent.Behavior.KindBase in set
      assert Ezagent.Behavior.Manage in set
    end

    test "EXPLICIT empty list on a SUPERSET Kind → base behaviors ONLY, never the declared superset (codex CRITICAL)" do
      # %{behaviors: []} is PRESENT-but-empty. It must NOT expand to the declared
      # superset (the bug the sentinel fixes). On first spawn this guarantees
      # Chat/Surface's create/init_slice never run.
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: []})

      assert set == BehaviorSet.base_behaviors()
      refute Ezagent.Behavior.Chat in set
      refute Ezagent.Behavior.Surface in set
      assert Ezagent.Behavior.KindBase in set
      assert Ezagent.Behavior.Manage in set
    end

    test "args :behaviors are intersected with declared (an undeclared module is ignored)" do
      set =
        BehaviorSet.init_set(SupersetKind, %{
          behaviors: [Ezagent.Behavior.Chat, Ezagent.Behavior.ApiKeys]
        })

      assert Ezagent.Behavior.Chat in set
      # ApiKeys is NOT declared by SupersetKind → must not be admitted.
      refute Ezagent.Behavior.ApiKeys in set
    end

    test "base behaviors with their own slice are NOT double-counted" do
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: [Ezagent.Behavior.KindBase]})
      assert Enum.count(set, &(&1 == Ezagent.Behavior.KindBase)) == 1
    end
  end
end
