defmodule Ezagent.Kind.BehaviorSetTest do
  use ExUnit.Case, async: true

  alias Ezagent.Kind.BehaviorSet

  defmodule SupersetKind do
    @behaviour Ezagent.Kind
    @impl true
    def type_name, do: :session
    @impl true
    def behaviors,
      do: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Surface, Ezagent.ActionSet.KindBase]

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
             Ezagent.Kind.behaviors_of(SupersetKind) ++ [Ezagent.ActionSet.Manage]
  end

  test "EXPLICIT empty captured list ([]) → base behaviors ONLY, NOT the declared superset (codex CRITICAL)" do
    # A PRESENT empty list is NOT the legacy sentinel: it intersects to nothing
    # declared, so the effective set is exactly base_behaviors — Chat/Surface
    # (declared) must be absent.
    slice_state = %{kind_base: %{state: %{behaviors: []}, transients: %{}}}

    assert BehaviorSet.effective_set(SupersetKind, slice_state) == BehaviorSet.base_behaviors()
    refute Ezagent.ActionSet.Session in BehaviorSet.effective_set(SupersetKind, slice_state)
    refute Ezagent.ActionSet.Surface in BehaviorSet.effective_set(SupersetKind, slice_state)
    assert Ezagent.ActionSet.KindBase in BehaviorSet.effective_set(SupersetKind, slice_state)
    assert Ezagent.ActionSet.Manage in BehaviorSet.effective_set(SupersetKind, slice_state)
  end

  test "captured subset → (declared ∩ captured) + base behaviors, declaration order preserved" do
    captured = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]
    slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

    # Surface is dropped (out of captured set); Chat + KindBase kept in
    # declaration order; Manage appended as a universal base behavior.
    assert BehaviorSet.effective_set(SupersetKind, slice_state) ==
             [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase, Ezagent.ActionSet.Manage]

    refute Ezagent.ActionSet.Surface in BehaviorSet.effective_set(SupersetKind, slice_state)
  end

  test "member?/2 reflects the effective set" do
    captured = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]
    slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

    assert BehaviorSet.member?(
             Ezagent.ActionSet.Session,
             BehaviorSet.effective_set(SupersetKind, slice_state)
           )

    refute BehaviorSet.member?(
             Ezagent.ActionSet.Surface,
             BehaviorSet.effective_set(SupersetKind, slice_state)
           )
  end

  describe "init_set/2 (first-spawn scoping, BEFORE any slice exists)" do
    test "args :behaviors subset → declared ∩ subset, PLUS the base behaviors" do
      # A chat-only spawn on the superset Kind. init_set is what
      # `init_fresh_first_spawn` enumerates on FIRST spawn (no :kind_base slice
      # yet), so Surface's
      # create/init_slice must NEVER appear here.
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: [Ezagent.ActionSet.Session]})

      assert Ezagent.ActionSet.Session in set
      # base behaviors are always present so KindBase can persist the set and
      # Manage stays reachable (universal-by-construction).
      assert Ezagent.ActionSet.KindBase in set
      assert Ezagent.ActionSet.Manage in set
      # out-of-set declared behavior is EXCLUDED — its create/init_slice must
      # not run on first spawn.
      refute Ezagent.ActionSet.Surface in set
    end

    test "ABSENT :behaviors arg → full declared list, PLUS base behaviors (legacy static-Kind preservation)" do
      # No :behaviors KEY at all → legacy path → full declared list.
      set = BehaviorSet.init_set(SupersetKind, %{})
      declared = Ezagent.Kind.behaviors_of(SupersetKind)

      assert Enum.all?(declared, &(&1 in set))
      assert Ezagent.ActionSet.KindBase in set
      assert Ezagent.ActionSet.Manage in set
    end

    test "EXPLICIT empty list on a SUPERSET Kind → base behaviors ONLY, never the declared superset (codex CRITICAL)" do
      # %{behaviors: []} is PRESENT-but-empty. It must NOT expand to the declared
      # superset (the bug the sentinel fixes). On first spawn this guarantees
      # Chat/Surface's create/init_slice never run.
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: []})

      assert set == BehaviorSet.base_behaviors()
      refute Ezagent.ActionSet.Session in set
      refute Ezagent.ActionSet.Surface in set
      assert Ezagent.ActionSet.KindBase in set
      assert Ezagent.ActionSet.Manage in set
    end

    test "args :behaviors KEEP an undeclared REAL Behavior (RF-1 generalized keystone)" do
      # RF-1 (role-foundation): a generic host admits recipe-loaded behaviors it
      # does NOT declare, as long as they are validated real Behaviors. ApiKeys
      # is a real Behavior NOT declared by SupersetKind → now KEPT (pre-RF-1 the
      # ∩-declared filter dropped it). authz still gates every action, so this
      # grants no privilege.
      set =
        BehaviorSet.init_set(SupersetKind, %{
          behaviors: [Ezagent.ActionSet.Session, Ezagent.ActionSet.ApiKeys]
        })

      assert Ezagent.ActionSet.Session in set
      assert Ezagent.ActionSet.ApiKeys in set
    end

    test "args :behaviors IGNORE an undeclared NON-Behavior module (RF-1 trust check)" do
      # The trust check that REPLACES ∩-declared is `real_behavior?/1`
      # (Code.ensure_loaded? + new_style?). A module that is not a real Behavior
      # is never admitted — declared or not.
      set =
        BehaviorSet.init_set(SupersetKind, %{
          behaviors: [Ezagent.ActionSet.Session, Ezagent.Kind.BehaviorSetTest.PlainModule]
        })

      assert Ezagent.ActionSet.Session in set
      refute Ezagent.Kind.BehaviorSetTest.PlainModule in set
    end

    test "base behaviors with their own slice are NOT double-counted" do
      set = BehaviorSet.init_set(SupersetKind, %{behaviors: [Ezagent.ActionSet.KindBase]})
      assert Enum.count(set, &(&1 == Ezagent.ActionSet.KindBase)) == 1
    end
  end

  # A behavior that DECLARES the `:surface` slice key but is NOT the
  # registered owner (`Ezagent.ActionSet.Surface`). Used to prove closure
  # is owner-MODULE based, not slice-key-presence based: a key collision
  # must NOT falsely satisfy Turn's required `:surface` dependency.
  defmodule FakeSurfaceOwner do
    use Ezagent.Lifecycle, state_slice: :surface
  end

  # RF-1: a plain module that is NOT a Behavior (no `use Ezagent.ActionSet`) —
  # `real_behavior?/1` must reject it from an instance behavior set.
  defmodule PlainModule do
    @moduledoc false
  end

  describe "resolve_closure/1 (required/optional siblings)" do
    test "passes when every required sibling owner is present" do
      set = [
        Ezagent.ActionSet.Session,
        Ezagent.ActionSet.Turn,
        Ezagent.ActionSet.Surface,
        # ConfigEvolve requires :sandbox + :identity owners (the agent-owned
        # config-evolve set, replacing the old session-side ConfigUpdate which
        # required :turns + :chat).
        Ezagent.ActionSet.ConfigEvolve,
        Ezagent.ActionSet.Sandbox,
        Ezagent.ActionSet.Identity,
        Ezagent.ActionSet.KindBase
      ]

      assert BehaviorSet.resolve_closure(set) == :ok
    end

    test "fails loud when a REQUIRED sibling owner is missing (Turn without Surface)" do
      set = [Ezagent.ActionSet.Session, Ezagent.ActionSet.Turn, Ezagent.ActionSet.KindBase]

      assert {:error, {:missing_required_siblings, missing}} = BehaviorSet.resolve_closure(set)
      assert {Ezagent.ActionSet.Turn, :surface} in missing
    end

    test "a slice-key COLLISION does NOT close the set (owner-module check, not key presence)" do
      # FakeSurfaceOwner declares state_slice :surface but is NOT
      # Ezagent.ActionSet.Surface — Turn's required :surface owner is still
      # ABSENT, so closure must FAIL. (Pre-fix this passed because the set
      # contributed a behavior whose state_slice/0 == :surface.)
      set = [Ezagent.ActionSet.Turn, FakeSurfaceOwner, Ezagent.ActionSet.KindBase]

      assert {:error, {:missing_required_siblings, missing}} = BehaviorSet.resolve_closure(set)
      assert {Ezagent.ActionSet.Turn, :surface} in missing
      # The REAL owner closes it.
      ok_set = [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface, Ezagent.ActionSet.KindBase]
      assert BehaviorSet.resolve_closure(ok_set) == :ok
    end

    test "OPTIONAL sibling absent is OK (Chat without Sandbox — today's behavior)" do
      set = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]
      assert BehaviorSet.resolve_closure(set) == :ok
    end
  end

  describe "validate_closure!/1 (raising wrapper used on the init path)" do
    test "returns the set unchanged when closed (passthrough for piping)" do
      set = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]
      assert BehaviorSet.validate_closure!(set) == set
    end

    test "RAISES UnclosedSetError when a required sibling OWNER is missing" do
      set = [Ezagent.ActionSet.Session, Ezagent.ActionSet.Turn, Ezagent.ActionSet.KindBase]

      err =
        assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
                     ~r/missing required sibling/,
                     fn -> BehaviorSet.validate_closure!(set) end

      assert {Ezagent.ActionSet.Turn, :surface} in err.missing
    end

    test "RAISES UnclosedSetError on a slice-key collision (FakeSurfaceOwner ≠ Surface)" do
      set = [Ezagent.ActionSet.Turn, FakeSurfaceOwner, Ezagent.ActionSet.KindBase]

      err =
        assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
                     ~r/missing required sibling/,
                     fn -> BehaviorSet.validate_closure!(set) end

      assert err.missing == [{Ezagent.ActionSet.Turn, :surface}]
    end
  end

  describe "resolve_closure/1 (unknown required slice owner — fail loud)" do
    test "a REQUIRED key with no @slice_owners entry fails loud (resolve_closure)" do
      # Drive an unknown required key through a reader registered in
      # @required_reads with a required key absent from @slice_owners. We
      # synthesize this via a local reader so the test is independent of
      # the production maps: assert the contract on the resolver directly.
      assert {:error, {:unknown_required_slice_owner, :nonexistent_slice}} =
               BehaviorSet.resolve_closure_for(
                 [UnknownKeyReader],
                 %{UnknownKeyReader => %{nonexistent_slice: :required}},
                 %{}
               )
    end

    test "validate_closure! RAISES on an unknown required slice owner" do
      assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError,
                   ~r/no owner module registered/,
                   fn ->
                     BehaviorSet.validate_closure_for!(
                       [UnknownKeyReader],
                       %{UnknownKeyReader => %{nonexistent_slice: :required}},
                       %{}
                     )
                   end
    end
  end

  defmodule UnknownKeyReader do
    use Ezagent.Lifecycle, state_slice: :unknown_key_reader
  end

  # P5-0b — a session-like Kind that REQUIRES an explicit (non-nil) :kind_base.
  # Same shape as SupersetKind but opts into the scoped nil-guard.
  defmodule SessionLikeKind do
    @behaviour Ezagent.Kind
    @impl true
    def type_name, do: :session
    @impl true
    def behaviors,
      do: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Surface, Ezagent.ActionSet.KindBase]

    @impl true
    def persistence, do: :ephemeral
    @impl true
    def supervisor, do: Ezagent.Kind.Server
    @impl true
    def requires_explicit_behavior_set?, do: true
  end

  describe "P5-0b scoped nil-:kind_base guard (effective_set/2)" do
    test "RAISES on a session Kind (requires_explicit_behavior_set? == true) with nil capture" do
      nil_slice = %{kind_base: %{state: %{behaviors: nil}, transients: %{}}}

      err =
        assert_raise Ezagent.Kind.BehaviorSet.MissingKindBaseError,
                     ~r/requires an explicit :kind_base/,
                     fn -> BehaviorSet.effective_set(SessionLikeKind, nil_slice) end

      assert err.kind_module == SessionLikeKind
    end

    test "RAISES on a session Kind with a MISSING :kind_base slice entirely" do
      assert_raise Ezagent.Kind.BehaviorSet.MissingKindBaseError, fn ->
        BehaviorSet.effective_set(SessionLikeKind, %{})
      end
    end

    test "a session Kind with a PRESENT explicit set is unaffected (no raise)" do
      captured = [Ezagent.ActionSet.Session, Ezagent.ActionSet.Surface]
      slice_state = %{kind_base: %{state: %{behaviors: captured}, transients: %{}}}

      set = BehaviorSet.effective_set(SessionLikeKind, slice_state)
      assert Ezagent.ActionSet.Session in set
      assert Ezagent.ActionSet.Surface in set
      assert Ezagent.ActionSet.KindBase in set
    end

    test "a LEGACY non-session Kind (no override) with nil capture is UNAFFECTED — still expands to declared" do
      # SupersetKind does NOT override requires_explicit_behavior_set? → the
      # guard must NOT fire; the legacy sentinel-nil → full-declared compat
      # path is preserved exactly.
      nil_slice = %{kind_base: %{state: %{behaviors: nil}, transients: %{}}}

      assert BehaviorSet.effective_set(SupersetKind, nil_slice) ==
               Ezagent.Kind.behaviors_of(SupersetKind) ++ [Ezagent.ActionSet.Manage]
    end
  end

  describe "P5-0b Ezagent.Kind.requires_explicit_behavior_set?/1 accessor" do
    test "false for a Kind without the optional callback" do
      refute Ezagent.Kind.requires_explicit_behavior_set?(SupersetKind)
    end

    test "true for a Kind that overrides it" do
      assert Ezagent.Kind.requires_explicit_behavior_set?(SessionLikeKind)
    end
  end
end
