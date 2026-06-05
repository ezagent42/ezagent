defmodule Ezagent.E2E.ScenarioTest do
  use ExUnit.Case, async: true
  import Ezagent.E2E.Step
  alias Ezagent.E2E.Scenario

  defp scen(steps), do: %Scenario{id: "t", base: nil, steps: steps}

  test "fp_chain has one cumulative fp per step" do
    sc =
      scen([
        step("a", run: fn c -> {:ok, c} end, await: fn _ -> :ok end, assert: fn _ -> :ok end),
        step("b", run: fn c -> {:ok, c} end, await: fn _ -> :ok end, assert: fn _ -> :ok end)
      ])

    chain = Scenario.fp_chain(sc, "img-1")
    assert length(chain) == 2
    assert Enum.all?(chain, &(byte_size(&1) == 64))
    assert Enum.uniq(chain) == chain
  end

  test "changing step K's callback changes fp(K) and everything after, NOT before" do
    # NOTE: callbacks MUST be inline literals at the `step` call site — the macro hashes
    # the AST there, so a var-passed fn would hash to the var name (identical for all).
    # Shared logic goes in @layer_inputs helpers, called inline.
    a =
      step("a",
        run: fn c -> {:ok, Map.put(c, :a, 1)} end,
        await: fn _ -> :ok end,
        assert: fn _ -> :ok end
      )

    b1 =
      step("b",
        run: fn c -> {:ok, Map.put(c, :b, 1)} end,
        await: fn _ -> :ok end,
        assert: fn _ -> :ok end
      )

    b2 =
      step("b",
        run: fn c -> {:ok, Map.put(c, :b, 999)} end,
        await: fn _ -> :ok end,
        assert: fn _ -> :ok end
      )

    cstep =
      step("c",
        run: fn c -> {:ok, Map.put(c, :c, 1)} end,
        await: fn _ -> :ok end,
        assert: fn _ -> :ok end
      )

    chain1 = Scenario.fp_chain(scen([a, b1, cstep]), "img-1")
    chain2 = Scenario.fp_chain(scen([a, b2, cstep]), "img-1")

    assert Enum.at(chain1, 0) == Enum.at(chain2, 0), "step 0 unchanged → same fp"
    refute Enum.at(chain1, 1) == Enum.at(chain2, 1), "step 1 changed → fp differs"
    refute Enum.at(chain1, 2) == Enum.at(chain2, 2), "downstream of change → fp differs"
  end

  test "env_image_id is part of the chain (image change invalidates all)" do
    sc =
      scen([
        step("a", run: fn c -> {:ok, c} end, await: fn _ -> :ok end, assert: fn _ -> :ok end)
      ])

    refute Scenario.fp_chain(sc, "img-1") == Scenario.fp_chain(sc, "img-2")
  end
end
