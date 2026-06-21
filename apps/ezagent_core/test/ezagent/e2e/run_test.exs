# A scenario module discoverable BY CONVENTION (ref -> Ezagent.E2E.Scenarios.<Camelized>).
# This is the mechanism that lets a higher-tier app (e.g. ezagent_domain_session)
# contribute a scenario without ezagent_core gaining a compile-time edge to it.
#
# Defined at TOP LEVEL (not nested in the test module) so its fully-qualified name
# is exactly Ezagent.E2E.Scenarios.RunTestDummy — a nested `defmodule` would prepend
# the enclosing module and break the convention lookup.
defmodule Ezagent.E2E.Scenarios.RunTestDummy do
  @moduledoc false
  import Ezagent.E2E.Step
  alias Ezagent.E2E.Scenario

  @spec scenario() :: Scenario.t()
  def scenario do
    %Scenario{
      id: "run_test_dummy",
      base: nil,
      steps: [
        step("ok",
          run: fn ctx -> {:ok, Map.put(ctx, "dummy", true)} end,
          await: fn _ -> :ok end,
          assert: fn ctx -> if ctx["dummy"], do: :ok, else: {:error, :no_dummy} end
        )
      ]
    }
  end
end

defmodule Ezagent.E2E.RunTest do
  use ExUnit.Case, async: true

  alias Ezagent.E2E.Run

  describe "run_scenario/2 resolution" do
    test "resolves a registered scenario name" do
      assert {:ok, %{}} = Run.run_scenario("scenario_0")
    end

    test "resolves an unregistered ref BY CONVENTION (ref -> Ezagent.E2E.Scenarios.<Camelized>)" do
      # "run_test_dummy" -> Macro.camelize -> "RunTestDummy" -> the top-level module above.
      assert {:ok, ctx} = Run.run_scenario("run_test_dummy")
      assert ctx["dummy"] == true
    end

    test "an unknown ref (no registered entry, no convention module) errors" do
      assert {:error, {:unknown_scenario, "no_such_scenario_xyz", names}} =
               Run.run_scenario("no_such_scenario_xyz")

      assert is_list(names)
    end
  end
end
