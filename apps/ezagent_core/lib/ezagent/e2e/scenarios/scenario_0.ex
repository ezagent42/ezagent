defmodule Ezagent.E2E.Scenarios.Scenario0 do
  @moduledoc """
  #21 PR-2 — E2E "scenario 0": the foundational scenario proving a BLANK, bootstrapped
  ESR is up + the harness can run steps in-node. Its end state is the base layer every
  other scenario builds on (the docker-base-layer analogy). Deliberately minimal + free
  of external refs so it's a robust smoke test.
  """

  import Ezagent.E2E.Step
  alias Ezagent.E2E.Scenario

  @spec scenario() :: Scenario.t()
  def scenario do
    %Scenario{
      id: "scenario_0",
      base: nil,
      steps: [
        step("node-alive",
          run: fn ctx -> {:ok, Map.put(ctx, "node", to_string(node()))} end,
          await: fn _ -> :ok end,
          assert: fn ctx -> if is_binary(ctx["node"]) and ctx["node"] != "", do: :ok, else: {:error, :no_node} end
        ),
        step("core-app-started",
          run: fn ctx ->
            apps = Application.started_applications() |> Enum.map(&elem(&1, 0))
            {:ok, Map.put(ctx, "core_started", :ezagent_core in apps)}
          end,
          await: fn _ -> :ok end,
          assert: fn ctx -> if ctx["core_started"], do: :ok, else: {:error, :ezagent_core_not_started} end
        )
      ]
    }
  end
end
