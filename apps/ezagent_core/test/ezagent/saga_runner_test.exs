defmodule Ezagent.SagaRunnerTest do
  @moduledoc """
  Tests for the SagaRunner primitive.

  Per SPEC `2026-05-28-router-behavior-kind-architecture.md` §5.4 + r2 codex
  HIGH-5 closure: SagaRunner is stateless linear orchestration with
  best-effort compensation. Tests cover:

    * Happy path (3 steps all succeed)
    * Forward-step failure → reverse compensation
    * Compensation failure → operator_repair_marker + error log
    * Steps without compensate fn are skipped during rollback
    * Effects accumulate across steps (effects_so_far populated)
    * Empty saga returns empty :ok shape
    * Forward fn raising counts as :error and triggers compensation
    * Compensate fn raising counts as compensation_failed
    * effects_so_far visible to compensate fn at point of compensation
    * Step ordering on success (step_results map)
  """
  # SagaRunner is pure; tests run async-safely. The repair-marker assertions
  # use `ExUnit.CaptureLog.with_log/1` (returns log atomically) rather than
  # `capture_log/1` (race-prone under heavy concurrent Logger activity).
  use ExUnit.Case, async: true

  alias Ezagent.SagaRunner

  describe "new/0" do
    test "returns an empty saga" do
      assert %SagaRunner.Saga{steps: []} = SagaRunner.new()
    end
  end

  describe "execute/2 — happy path" do
    test "empty saga returns {:ok, %{step_results: %{}, events: []}}" do
      assert {:ok, %{step_results: results, events: events}} =
               SagaRunner.execute(SagaRunner.new(), %{})

      assert results == %{}
      assert events == []
    end

    test "3 steps all succeed; step_results keyed by step name; events accumulated" do
      saga =
        SagaRunner.new()
        |> SagaRunner.run(:lock, fn _ctx, _eff -> {:ok, :locked, [{:set, :locked, true}]} end)
        |> SagaRunner.run(:transfer, fn _ctx, _eff -> {:ok, :transferred, [{:emit, :debited}]} end)
        |> SagaRunner.run(:notify, fn _ctx, _eff -> {:ok, :notified, [{:notify, :done}]} end)

      assert {:ok, %{step_results: results, events: events}} =
               SagaRunner.execute(saga, %{uri: "test://foo"})

      assert results == %{lock: :locked, transfer: :transferred, notify: :notified}
      assert events == [{:set, :locked, true}, {:emit, :debited}, {:notify, :done}]
    end
  end

  describe "execute/2 — forward failure & compensation" do
    test "mid-saga forward failure compensates prior steps in REVERSE order" do
      # Use an agent to record the order of compensations.
      {:ok, log} = Agent.start_link(fn -> [] end)

      record = fn step ->
        fn _err, _eff, _ctx ->
          Agent.update(log, fn xs -> [step | xs] end)
          {:ok, :compensated}
        end
      end

      saga =
        SagaRunner.new()
        |> SagaRunner.run(:a, fn _ctx, _eff -> {:ok, :a, []} end, record.(:a))
        |> SagaRunner.run(:b, fn _ctx, _eff -> {:ok, :b, []} end, record.(:b))
        |> SagaRunner.run(:c, fn _ctx, _eff -> {:error, :boom} end, record.(:c))

      assert {:error, err} = SagaRunner.execute(saga, %{})
      assert err.failed_at == :c
      assert err.reason == :boom
      # `:c` forward never succeeded, so its compensate is NOT called.
      # Prior steps :b then :a compensate in reverse.
      assert err.compensated == [:b, :a]
      assert err.operator_repair_marker == nil

      # Verify call ORDER was :b first, then :a (most-recent first).
      assert Agent.get(log, & &1) == [:a, :b]
    end

    test "forward fn raising counts as failure + triggers compensation" do
      {:ok, log} = Agent.start_link(fn -> [] end)

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx ->
            Agent.update(log, fn xs -> [:a | xs] end)
            {:ok, :compensated}
          end
        )
        |> SagaRunner.run(:b, fn _ctx, _eff -> raise "kaboom" end)

      assert {:error, err} = SagaRunner.execute(saga, %{})
      assert err.failed_at == :b
      assert match?({:forward_raised, _}, err.reason)
      assert err.compensated == [:a]
      assert Agent.get(log, & &1) == [:a]
    end
  end

  describe "execute/2 — compensation failure & operator repair" do
    test "compensate fn returning {:error, :compensation_failed, _} writes marker + halts" do
      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx -> {:error, :compensation_failed, :db_down} end
        )
        |> SagaRunner.run(:b, fn _ctx, _eff -> {:error, :boom} end)

      # `with_log/1` ties the log capture lifetime to the function call AND
      # returns both the result + the captured log atomically — more robust
      # than `capture_log/1` under heavy concurrent Logger activity.
      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> SagaRunner.execute(saga, %{}) end)

      assert {:error, err} = result
      assert err.failed_at == :b
      assert err.reason == :boom
      # :a's compensate FAILED, so it's NOT in the compensated list.
      assert err.compensated == []
      assert is_binary(err.operator_repair_marker)
      assert byte_size(err.operator_repair_marker) == 32

      assert log =~ "[SagaRunner] operator-repair marker #{err.operator_repair_marker}"
      assert log =~ "db_down"
    end

    test "compensate fn RAISING writes marker + halts (treated as compensation_failed)" do
      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx -> raise "compensate exploded" end
        )
        |> SagaRunner.run(:b, fn _ctx, _eff -> {:error, :boom} end)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> SagaRunner.execute(saga, %{}) end)

      assert {:error, err} = result
      assert err.compensated == []
      assert is_binary(err.operator_repair_marker)

      assert log =~ "[SagaRunner] operator-repair marker"
      assert log =~ "compensate_raised"
    end

    test "partial compensation: later compensate succeeds, earlier compensate fails" do
      # 3 steps; forward of :c fails. Reverse compensation walks b → a.
      # :b's compensate succeeds (added to compensated list); :a's fails
      # → marker written, walk aborts, :a NOT in compensated.
      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx -> {:error, :compensation_failed, :a_repair_needed} end
        )
        |> SagaRunner.run(
          :b,
          fn _ctx, _eff -> {:ok, :b, []} end,
          fn _err, _eff, _ctx -> {:ok, :compensated} end
        )
        |> SagaRunner.run(:c, fn _ctx, _eff -> {:error, :c_boom} end)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn -> SagaRunner.execute(saga, %{}) end)

      assert {:error, err} = result
      assert err.failed_at == :c
      assert err.reason == :c_boom
      # :b compensated successfully; :a compensation failed.
      assert err.compensated == [:b]
      assert is_binary(err.operator_repair_marker)
    end
  end

  describe "execute/2 — steps without compensate fn" do
    test "nil compensate is skipped during reverse-walk (no error, just skipped)" do
      {:ok, log} = Agent.start_link(fn -> [] end)

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx ->
            Agent.update(log, fn xs -> [:a | xs] end)
            {:ok, :compensated}
          end
        )
        # :b has no compensate
        |> SagaRunner.run(:b, fn _ctx, _eff -> {:ok, :b, []} end)
        |> SagaRunner.run(:c, fn _ctx, _eff -> {:error, :boom} end)

      assert {:error, err} = SagaRunner.execute(saga, %{})
      # :b is silently skipped (no compensate). :a IS compensated.
      assert err.compensated == [:a]
      assert Agent.get(log, & &1) == [:a]
    end
  end

  describe "execute/2 — effect propagation" do
    test "effects_so_far is populated for each step's forward fn (flat list, in order)" do
      saga =
        SagaRunner.new()
        |> SagaRunner.run(:a, fn _ctx, eff ->
          assert eff == []
          {:ok, :a, [{:set, :step, :a}]}
        end)
        |> SagaRunner.run(:b, fn _ctx, eff ->
          assert eff == [{:set, :step, :a}]
          {:ok, :b, [{:set, :step, :b}, {:emit, :did_b}]}
        end)
        |> SagaRunner.run(:c, fn _ctx, eff ->
          assert eff == [{:set, :step, :a}, {:set, :step, :b}, {:emit, :did_b}]
          {:ok, :c, []}
        end)

      assert {:ok, %{events: events}} = SagaRunner.execute(saga, %{})
      assert events == [{:set, :step, :a}, {:set, :step, :b}, {:emit, :did_b}]
    end

    test "compensate fn sees effects_so_far INCLUDING its own step's effects" do
      # Step :a returns effects [{:set, :a, 1}]. When :b fails, :a's
      # compensate runs and should see :a's effects so it can undo them.
      effects_seen_by_a_compensate =
        :ets.new(:effects_seen_by_a_compensate, [:public, :set])

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn _ctx, _eff -> {:ok, :a, [{:set, :a, 1}]} end,
          fn _err, eff, _ctx ->
            :ets.insert(effects_seen_by_a_compensate, {:eff, eff})
            {:ok, :compensated}
          end
        )
        |> SagaRunner.run(:b, fn _ctx, _eff -> {:error, :boom} end)

      assert {:error, err} = SagaRunner.execute(saga, %{})
      assert err.compensated == [:a]

      assert [{:eff, eff}] = :ets.lookup(effects_seen_by_a_compensate, :eff)
      assert eff == [{:set, :a, 1}]
    end

    test "ctx is immutable across steps (each forward + compensate sees the SAME ctx)" do
      ctx = %{uri: "test://immutable", flag: :original}

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn c, _eff ->
            assert c == ctx
            {:ok, :a, []}
          end,
          fn _err, _eff, c ->
            assert c == ctx
            {:ok, :compensated}
          end
        )
        |> SagaRunner.run(:b, fn c, _eff ->
          assert c == ctx
          {:error, :boom}
        end)

      assert {:error, _} = SagaRunner.execute(saga, ctx)
    end
  end

  describe "execute/2 — pathological returns" do
    test "forward fn returning bad shape is treated as :error with reason {:bad_forward_return, _}" do
      saga =
        SagaRunner.new()
        |> SagaRunner.run(:a, fn _ctx, _eff -> :not_a_valid_return end)

      assert {:error, err} = SagaRunner.execute(saga, %{})
      assert err.failed_at == :a
      assert match?({:bad_forward_return, :not_a_valid_return}, err.reason)
      assert err.compensated == []
    end
  end

  describe "run/4 — guards" do
    test "raises on non-atom step name" do
      assert_raise FunctionClauseError, fn ->
        SagaRunner.run(SagaRunner.new(), "not_atom", fn _, _ -> {:ok, :x, []} end)
      end
    end

    test "raises on forward fn with wrong arity" do
      assert_raise FunctionClauseError, fn ->
        SagaRunner.run(SagaRunner.new(), :bad, fn -> {:ok, :x, []} end)
      end
    end
  end

  describe "module example doc" do
    test "the @moduledoc example shape executes successfully" do
      cache_unlocked = :counters.new(1, [])

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :lock,
          fn _ctx, _eff -> {:ok, :locked, [{:set, :locked, true}]} end,
          fn _err, _eff, _ctx ->
            :counters.add(cache_unlocked, 1, 1)
            {:ok, :compensated}
          end
        )
        |> SagaRunner.run(:transfer, fn _ctx, _eff -> {:ok, :ok, []} end)

      assert {:ok, %{step_results: %{lock: :locked, transfer: :ok}}} =
               SagaRunner.execute(saga, %{uri: "test://acct/1"})

      # Forward path didn't unlock the cache (no failure → no compensation).
      assert :counters.get(cache_unlocked, 1) == 0
    end
  end
end
