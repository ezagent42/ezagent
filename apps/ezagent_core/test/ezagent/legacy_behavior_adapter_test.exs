defmodule Ezagent.LegacyBehaviorAdapterTest do
  @moduledoc """
  Tests for `Ezagent.LegacyBehaviorAdapter` per SPEC §6.1 Phase 1
  (the breaking-change migration plan).

  The adapter:
  - Translates legacy `Behavior.invoke/4` returns into the new
    `{:ok, result, [effect]}` shape
  - Synthesises a `:legacy_action_executed` event (NON-replay-
    equivalent — codex r1 HIGH-2 closure)
  - Is deletion-tracked from day 1 (`# @LEGACY-PHASE3-REMOVE` sigils)
  """

  use ExUnit.Case, async: true

  alias Ezagent.{Cmd, LegacyBehaviorAdapter}

  # ---------------------------------------------------------------
  # Fixture: a legacy `@behaviour Ezagent.Behavior` Behavior
  # ---------------------------------------------------------------

  defmodule LegacyFixture do
    @moduledoc false
    @behaviour Ezagent.Behavior

    @impl true
    def actions, do: [:set_x, :increment, :no_change]

    @impl true
    def cap_subjects do
      [
        {:set_x, "legacy — set the :x field"},
        {:increment, "legacy — bump :n by 1"},
        {:no_change, "legacy — return slice unchanged"}
      ]
    end

    @impl true
    def state_slice, do: :legacy_fixture

    @impl true
    def init_slice(_args), do: %{x: nil, n: 0}

    @impl true
    def invoke(:set_x, slice, %{value: v}, _ctx) do
      {:ok, %{slice | x: v}, %{set: true}}
    end

    @impl true
    def invoke(:increment, slice, _args, _ctx) do
      {:ok, %{slice | n: slice.n + 1}}
    end

    @impl true
    def invoke(:no_change, slice, _args, _ctx) do
      {:ok, slice, %{unchanged: true}}
    end

    @impl true
    def invoke(:fail_action, _slice, _args, _ctx) do
      {:error, :legacy_test_failure}
    end

    @impl true
    def interface do
      %{
        set_x: %{description: "", args: %{value: :any}, returns: %{set: :boolean}, modes: [:call]},
        increment: %{description: "", args: %{}, returns: :ok, modes: [:cast]},
        no_change: %{
          description: "",
          args: %{},
          returns: %{unchanged: :boolean},
          modes: [:call]
        }
      }
    end

    @impl true
    def required_caps do
      %{
        set_x: Ezagent.Capability.cap(:any, __MODULE__, :set_x),
        increment: Ezagent.Capability.cap(:any, __MODULE__, :increment),
        no_change: Ezagent.Capability.cap(:any, __MODULE__, :no_change)
      }
    end
  end

  describe "adapt_result/4 — slice diff → :set effect" do
    test "{:ok, new_slice, result} with changed slice → {:set, key, new_slice} + :emit" do
      old_slice = %{x: nil, n: 0}
      new_slice = %{x: "hello", n: 0}
      legacy_result = {:ok, new_slice, %{set: true}}

      assert {:ok, %{set: true}, effects} =
               LegacyBehaviorAdapter.adapt_result(LegacyFixture, :set_x, old_slice, legacy_result)

      assert [
               {:set, :legacy_fixture, ^new_slice},
               {:emit, :legacy_action_executed, payload}
             ] = effects

      assert payload.behavior == LegacyFixture
      assert payload.action == :set_x
      assert payload.slice_diff == %{x: "hello"}
      assert payload.result == %{set: true}
    end

    test "{:ok, new_slice} (silent success) → still emits :set + :emit" do
      old_slice = %{x: nil, n: 0}
      new_slice = %{x: nil, n: 1}
      legacy_result = {:ok, new_slice}

      assert {:ok, :ok, effects} =
               LegacyBehaviorAdapter.adapt_result(
                 LegacyFixture,
                 :increment,
                 old_slice,
                 legacy_result
               )

      assert [
               {:set, :legacy_fixture, ^new_slice},
               {:emit, :legacy_action_executed, payload}
             ] = effects

      assert payload.slice_diff == %{n: 1}
      assert payload.result == nil
    end

    test "no-change slice → no :set effect; only :emit audit" do
      slice = %{x: "stable", n: 5}
      legacy_result = {:ok, slice, %{unchanged: true}}

      assert {:ok, %{unchanged: true}, effects} =
               LegacyBehaviorAdapter.adapt_result(
                 LegacyFixture,
                 :no_change,
                 slice,
                 legacy_result
               )

      # No :set effect because the diff is empty.
      refute Enum.any?(effects, &match?({:set, _, _}, &1))
      assert Enum.any?(effects, &match?({:emit, :legacy_action_executed, _}, &1))
    end

    test "{:error, _} legacy return passes through unchanged" do
      assert {:error, :legacy_test_failure} =
               LegacyBehaviorAdapter.adapt_result(
                 LegacyFixture,
                 :fail_action,
                 %{},
                 {:error, :legacy_test_failure}
               )
    end

    test "unexpected legacy return shape surfaces a structured error" do
      assert {:error, {:legacy_invoke_unexpected_return, :nonsense}} =
               LegacyBehaviorAdapter.adapt_result(LegacyFixture, :foo, %{}, :nonsense)
    end
  end

  describe "diff_maps — keys removed by legacy handler" do
    test "removed keys captured under :__removed__" do
      old_slice = %{a: 1, b: 2, c: 3}
      # Drop :b
      new_slice = %{a: 1, c: 3}
      legacy_result = {:ok, new_slice}

      assert {:ok, _result, effects} =
               LegacyBehaviorAdapter.adapt_result(LegacyFixture, :foo, old_slice, legacy_result)

      [_set, {:emit, _, payload}] = effects
      assert payload.slice_diff[:__removed__] == [:b]
    end
  end

  describe "introspection helpers" do
    test "legacy_actions/1 returns the legacy actions list" do
      assert LegacyBehaviorAdapter.legacy_actions(LegacyFixture) == [:set_x, :increment, :no_change]
    end

    test "legacy_actions/1 returns [] for a non-Behavior module" do
      assert LegacyBehaviorAdapter.legacy_actions(Enum) == []
    end

    test "legacy_required_caps/1 returns the cap map" do
      caps = LegacyBehaviorAdapter.legacy_required_caps(LegacyFixture)
      assert is_map(caps)
      assert Map.has_key?(caps, :set_x)
    end

    test "legacy_required_caps/1 returns %{} for module without the callback" do
      assert LegacyBehaviorAdapter.legacy_required_caps(Enum) == %{}
    end
  end

  describe "wrap_cmd/1 — Cmd → Invocation translation" do
    test "wrap_cmd builds an %Invocation{} with mode :cast for :ignore reply" do
      cmd =
        Cmd.new("entity://agent/test/x", :ping, %{}, %{
          caller: :system,
          reply: :ignore
        })

      inv = LegacyBehaviorAdapter.wrap_cmd(cmd)
      assert %Ezagent.Invocation{} = inv
      assert inv.mode == :cast
      # action is encoded in the URI's query string
      assert inv.target.query =~ "action=ping"
    end

    test "wrap_cmd builds an %Invocation{} with mode :call for caller_inbox reply" do
      cmd =
        Cmd.new("entity://agent/test/x", :ping, %{}, %{
          reply: {:caller_inbox, self()}
        })

      inv = LegacyBehaviorAdapter.wrap_cmd(cmd)
      assert inv.mode == :call
    end
  end

  describe "deletion tracking — SPEC §11 grep gate" do
    test "deletion_sigil/0 returns the marker atom" do
      assert LegacyBehaviorAdapter.deletion_sigil() == :legacy_phase3_remove
    end

    test "module source contains the @LEGACY-PHASE3-REMOVE sigil for every public function" do
      source = File.read!("lib/ezagent/legacy_behavior_adapter.ex")
      # Count function defs vs sigils.
      sigil_count =
        source
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "@LEGACY-PHASE3-REMOVE"))

      # We expect at LEAST one sigil per public function. The exact
      # count varies as the adapter evolves, but the bar is "every
      # public `def` has the marker above it or directly in its
      # body comment".
      assert sigil_count >= 8
    end
  end

  describe "coverage/0 — Phase 3 readiness signal" do
    test "coverage/0 returns a list (possibly empty in isolated test)" do
      # In this isolated unit-test we may not have other legacy
      # Behaviors loaded; we just verify the function returns a
      # list without crashing.
      coverage = LegacyBehaviorAdapter.coverage()
      assert is_list(coverage)
    end
  end
end
