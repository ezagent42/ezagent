defmodule Ezagent.E2E.Run do
  @moduledoc """
  #21 PR-2 — IN-NODE entry point for running an E2E scenario.

  Scenarios must run INSIDE the live ESR node (SQLite is single-writer and Kind state is
  in-memory), so `mix ezagent.e2e.run` reaches this via `:rpc.call` (mirroring the
  `mix ezagent` CLI). Each scenario module exposes `scenario/0 :: %Ezagent.E2E.Scenario{}`.
  """

  alias Ezagent.E2E.Runner

  @scenarios %{
    "scenario_0" => Ezagent.E2E.Scenarios.Scenario0
  }

  @doc "Run a registered scenario by name. `opts` pass through to `Runner.run/2` (e.g. `:up_to`)."
  @spec run_scenario(String.t(), keyword()) :: Runner.result()
  def run_scenario(ref, opts \\ []) when is_binary(ref) do
    with {:ok, mod} <- resolve(ref) do
      Runner.run(mod.scenario(), opts)
    end
  end

  @doc "List registered scenario names."
  @spec list() :: [String.t()]
  def list, do: Map.keys(@scenarios)

  defp resolve(ref) do
    case Map.fetch(@scenarios, ref) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_scenario, ref, Map.keys(@scenarios)}}
    end
  end
end
