defmodule Ezagent.E2E.RunnerTest do
  use ExUnit.Case, async: true
  import Ezagent.E2E.Step
  alias Ezagent.E2E.{Runner, Scenario}

  defp scen(steps), do: %Scenario{id: "t", base: nil, steps: steps}

  test "runs steps in order, threading ctx, returns final ctx" do
    sc =
      scen([
        step("a",
          run: fn c -> {:ok, Map.put(c, :a, 1)} end,
          await: fn _ -> :ok end,
          assert: fn c -> if c[:a] == 1, do: :ok, else: {:error, :no_a} end
        ),
        step("b",
          run: fn c -> {:ok, Map.put(c, :b, c[:a] + 1)} end,
          await: fn _ -> :ok end,
          assert: fn _ -> :ok end
        )
      ])

    assert {:ok, %{a: 1, b: 2}} = Runner.run(sc)
  end

  test "run returning {:error,_} stops with a labelled error" do
    sc =
      scen([
        step("boom",
          run: fn _ -> {:error, :kaboom} end,
          await: fn _ -> :ok end,
          assert: fn _ -> :ok end
        )
      ])

    assert {:error, {:step_run_failed, "boom", 0, :kaboom}} = Runner.run(sc)
  end

  test "await pending stops the run (no snapshot would be taken)" do
    sc =
      scen([
        step("wait",
          run: fn c -> {:ok, c} end,
          await: fn _ -> {:error, :not_settled} end,
          assert: fn _ -> :ok end
        )
      ])

    assert {:error, {:step_await_pending, "wait", 0, :not_settled}} = Runner.run(sc)
  end

  test "assert failure stops the run AFTER await (so a layer would not be published)" do
    sc =
      scen([
        step("chk",
          run: fn c -> {:ok, c} end,
          await: fn _ -> :ok end,
          assert: fn _ -> {:error, :wrong} end
        )
      ])

    assert {:error, {:step_assert_failed, "chk", 0, :wrong}} = Runner.run(sc)
  end

  test "up_to (name) stops after that step — tier-2 pre-trigger seeding" do
    sc =
      scen([
        step("seed",
          run: fn c -> {:ok, Map.put(c, :seeded, true)} end,
          await: fn _ -> :ok end,
          assert: fn _ -> :ok end
        ),
        step("trigger",
          run: fn _ -> {:error, :should_not_run} end,
          await: fn _ -> :ok end,
          assert: fn _ -> :ok end
        )
      ])

    assert {:ok, %{seeded: true}} = Runner.run(sc, up_to: "seed")
  end

  test "up_to with unknown step name → clear error" do
    sc =
      scen([
        step("only", run: fn c -> {:ok, c} end, await: fn _ -> :ok end, assert: fn _ -> :ok end)
      ])

    assert {:error, {:unknown_step, "nope"}} = Runner.run(sc, up_to: "nope")
  end
end
