defmodule Ezagent.BehaviorTest do
  @moduledoc """
  Tests for the new `use Ezagent.ActionSet` macro per SPEC §2.2 +
  §4.4 effect grammar.
  """

  use ExUnit.Case, async: true

  alias Ezagent.{ActionSet, Cmd}

  # ---------------------------------------------------------------
  # Fixture: a new-style ActionSet used by the action-declaration tests
  # ---------------------------------------------------------------

  defmodule SimpleBehavior do
    @moduledoc false
    use Ezagent.ActionSet

    action(:greet,
      args: %{name: :string},
      returns: %{greeted: :boolean},
      caps: [:greet],
      description: "say hello",
      modes: [:call]
    )

    action(:bump,
      args: %{},
      returns: %{count: :integer},
      caps: [:bump],
      modes: [:cast]
    )

    def handle_greet(%{name: name}, _ctx) do
      {:ok, %{greeted: true, name: name},
       [
         {:set, :last_greeted, name},
         {:emit, :greeted, %{name: name}}
       ]}
    end

    def handle_bump(_args, ctx) do
      cur = ctx[:read].(:count, 0)
      {:ok, %{count: cur + 1}, [{:set, :count, cur + 1}]}
    end
  end

  describe "use Ezagent.ActionSet — declaration" do
    test "__action_names__/0 returns declared action atoms" do
      assert :greet in SimpleBehavior.__action_names__()
      assert :bump in SimpleBehavior.__action_names__()
    end

    test "__action_spec__/1 returns full spec for a declared action" do
      spec = SimpleBehavior.__action_spec__(:greet)
      assert spec.name == :greet
      assert spec.args == %{name: :string}
      assert spec.returns == %{greeted: :boolean}
      assert spec.caps == [:greet]
      assert spec.modes == [:call]
      assert spec.description == "say hello"
    end

    test "__action_spec__/1 returns nil for an undeclared action" do
      assert SimpleBehavior.__action_spec__(:nonexistent) == nil
    end

    test "derived legacy callback actions/0 lists action names" do
      assert :greet in SimpleBehavior.actions()
      assert :bump in SimpleBehavior.actions()
    end

    test "derived legacy callback interface/0 has action shapes" do
      i = SimpleBehavior.interface()
      assert i[:greet].args == %{name: :string}
      assert i[:greet].modes == [:call]
      assert i[:bump].modes == [:cast]
    end

    test "derived legacy callback cap_subjects/0 includes descriptions" do
      subjects = SimpleBehavior.cap_subjects()
      assert {:greet, "say hello"} in subjects
    end

    test "new_style?/1 detects the new contract" do
      assert ActionSet.new_style?(SimpleBehavior)
      refute ActionSet.new_style?(Enum)
    end
  end

  describe "compile-time validation" do
    test "missing handle_<action>/2 raises CompileError" do
      assert_raise CompileError, ~r/missing.*handle_undeclared/, fn ->
        Code.compile_string("""
        defmodule TestMissingHandler do
          use Ezagent.ActionSet
          action :undeclared, args: %{}, returns: :ok, caps: [:x]
        end
        """)
      end
    end

    test "action without :args raises CompileError" do
      assert_raise CompileError, ~r/missing required key :args/, fn ->
        Code.compile_string("""
        defmodule TestNoArgs do
          use Ezagent.ActionSet
          action :foo, returns: :ok
          def handle_foo(_a, _c), do: {:ok, :ok, []}
        end
        """)
      end
    end

    test "action without :returns raises CompileError" do
      assert_raise CompileError, ~r/missing required key :returns/, fn ->
        Code.compile_string("""
        defmodule TestNoReturns do
          use Ezagent.ActionSet
          action :foo, args: %{}
          def handle_foo(_a, _c), do: {:ok, :ok, []}
        end
        """)
      end
    end
  end

  describe "apply_effects/2 — phase ordering" do
    test ":set effects mutate state in declared order" do
      effects = [
        {:set, :a, 1},
        {:set, :b, 2},
        {:set, :a, 3}
      ]

      assert {:ok, result} = ActionSet.apply_effects(effects, %{})
      assert result.state == %{a: 3, b: 2}
    end

    test ":emit effects are bucketed for event log in declared order" do
      effects = [
        {:emit, :first, %{n: 1}},
        {:emit, :second, %{n: 2}}
      ]

      assert {:ok, result} = ActionSet.apply_effects(effects, %{})
      assert result.events == [{:emit, :first, %{n: 1}}, {:emit, :second, %{n: 2}}]
    end

    test ":dispatch effects collect into dispatches bucket" do
      cmd = Cmd.new("entity://test/agent/x", :ping, %{}, %{caller: :vm_internal})

      assert {:ok, result} = ActionSet.apply_effects([{:dispatch, cmd}], %{})
      assert [{:dispatch, ^cmd}] = result.dispatches
    end

    test ":notify effects collect into notifies bucket" do
      effects = [{:notify, "topic", %{msg: "x"}}]

      assert {:ok, result} = ActionSet.apply_effects(effects, %{})
      assert [{:notify, "topic", %{msg: "x"}}] = result.notifies
    end

    test ":halt short-circuits — set/emit effects before halt do NOT commit" do
      effects = [
        {:set, :a, 1},
        {:halt, :test_halt},
        {:set, :b, 2}
      ]

      assert {:halt, :test_halt, partial} = ActionSet.apply_effects(effects, %{starting: true})
      # Pre-halt :set DID apply to in-memory state per Phase 1 simple
      # reducer; the caller (Router) must NOT persist it. This is the
      # contract — the {:halt, _, partial} return is the signal to
      # roll back.
      assert partial.state == %{starting: true, a: 1}
    end

    test "unknown effect raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        ActionSet.apply_effects([{:nonsense, :foo}], %{})
      end
    end
  end

  describe "apply_effects/2 — :effect_returning + {:ref, ...}" do
    test "ref substitution from :effect_returning binding" do
      effects = [
        {:effect_returning, fn -> %{id: 42, body: "hello"} end, [], bind_as: :stored},
        {:set, :last_id, {:ref, :stored, [:id]}},
        {:emit, :stored_event, %{body: {:ref, :stored, [:body]}}}
      ]

      assert {:ok, result} = ActionSet.apply_effects(effects, %{})
      # :set ran in phase 1 (before :effect_returning) — but at
      # phase-1 time the ref didn't substitute yet, so the
      # in-state value is the literal {:ref, ...} tuple.
      # The IMPORTANT contract: any downstream effect that USES the
      # ref (events/notifies/dispatches) gets the substituted value
      # after :effect_returning phase 3 runs.
      assert [{:emit, :stored_event, %{body: "hello"}}] = result.events
    end

    test "MFA-form :effect_returning binding" do
      defmodule MfaTarget do
        def returner, do: %{value: 7}
      end

      effects = [
        {:effect_returning, {MfaTarget, :returner}, [], bind_as: :r},
        {:notify, "t", {:ref, :r, [:value]}}
      ]

      assert {:ok, result} = ActionSet.apply_effects(effects, %{})
      assert [{:notify, "t", 7}] = result.notifies
    end
  end

  describe "apply_effects/2 — :dispatch_returning bucketing (SPEC 2026-05-29)" do
    test "valid :dispatch_returning is bucketed into :dispatches_returning, preserving declared order" do
      cmd1 =
        Cmd.new("entity://acme/user/alice", :ping, %{}, %{
          caller: :vm_internal,
          reply: {:caller_inbox, self()}
        })

      cmd2 =
        Cmd.new("entity://acme/user/bob", :ping, %{}, %{
          caller: :vm_internal,
          reply: {:caller_inbox, self()}
        })

      effects = [
        {:dispatch_returning, cmd1, bind_as: :alice},
        {:set, :foo, :bar},
        {:dispatch_returning, cmd2, bind_as: :bob}
      ]

      assert {:ok, result} = ActionSet.apply_effects(effects, %{})

      # apply_effects/2 is pure — it bucketises but does NOT execute
      # the returning dispatches (the executor runs them via Router).
      # Order must be preserved.
      assert [
               {:dispatch_returning, ^cmd1, [bind_as: :alice]},
               {:dispatch_returning, ^cmd2, [bind_as: :bob]}
             ] = result.dispatches_returning

      # :set still applied eagerly into state.
      assert result.state.foo == :bar
    end

    test ":dispatch_returning without :bind_as raises ArgumentError" do
      cmd =
        Cmd.new("entity://acme/user/alice", :ping, %{}, %{
          caller: :vm_internal,
          reply: {:caller_inbox, self()}
        })

      assert_raise ArgumentError, ~r/dispatch_returning requires.*bind_as/, fn ->
        ActionSet.apply_effects([{:dispatch_returning, cmd, []}], %{})
      end
    end

    test ":dispatch_returning with non-Cmd target raises ArgumentError via unknown-effect path" do
      # Shape doesn't match the dispatch_returning bucket pattern
      # (no %Cmd{}) — falls through to the unknown-effect raise.
      assert_raise ArgumentError, ~r/unknown effect/, fn ->
        ActionSet.apply_effects(
          [{:dispatch_returning, :not_a_cmd, [bind_as: :x]}],
          %{}
        )
      end
    end
  end

  describe "ActionSet.action_names/1 + action_spec/2 introspection" do
    test "action_names/1 lists actions of a new-style module" do
      names = ActionSet.action_names(SimpleBehavior)
      assert :greet in names
    end

    test "action_names/1 returns [] for a legacy module" do
      # Use any module that doesn't `use Ezagent.ActionSet` — Enum suffices.
      assert ActionSet.action_names(Enum) == []
    end

    test "action_spec/2 returns the full spec" do
      spec = ActionSet.action_spec(SimpleBehavior, :greet)
      assert spec.description == "say hello"
    end
  end

  describe "ActionSet.data_owner_of/2 — re-export (SPEC 2026-05-29 §2b)" do
    defmodule DataOwnerBehavior do
      @moduledoc false
      def data_owner(%URI{} = uri), do: %URI{uri | path: "/owner"}
      def data_owner(_), do: :no_owner
    end

    test "delegates to behavior.data_owner/1 for concrete instances" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/foo")
      assert %URI{path: "/owner"} = ActionSet.data_owner_of(DataOwnerBehavior, uri)
    end

    test "returns :no_owner for non-URI instances" do
      assert ActionSet.data_owner_of(DataOwnerBehavior, :any) == :no_owner
    end

    test "returns :no_owner when behavior doesn't export data_owner/1" do
      # `Enum` doesn't `use Ezagent.ActionSet` + has no data_owner/1.
      assert ActionSet.data_owner_of(Enum, :any) == :no_owner
    end
  end
end
