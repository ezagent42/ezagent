defmodule Ezagent.E2E.Run do
  @moduledoc """
  #21 PR-2 — IN-NODE entry point for running an E2E scenario.

  Scenarios must run INSIDE the live Ezagent node (Kind state is in-memory /
  node-local), so `mix ezagent.e2e.run` reaches this via `:rpc.call` (mirroring the
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

  # Resolve a scenario ref to its module. Registered refs win; anything else is
  # resolved BY CONVENTION at runtime — `ref` → `Ezagent.E2E.Scenarios.<Camelized>`.
  #
  # The convention path is what lets a scenario module live in a HIGHER tier than
  # this core harness (e.g. `Ezagent.E2E.Scenarios.AgentContractG4` in
  # `ezagent_domain_session`, which needs SessionCreator/Tools/migrate_session):
  # `Module.concat/1` builds the atom at runtime, so there is NO compile-time
  # `ezagent_core → ezagent_domain_*` edge (the umbrella acyclic gate stays green).
  # The module just has to be LOADED in the running node, which it is.
  @spec resolve(String.t()) :: {:ok, module()} | {:error, term()}
  defp resolve(ref) do
    case Map.fetch(@scenarios, ref) do
      {:ok, mod} -> {:ok, mod}
      :error -> resolve_by_convention(ref)
    end
  end

  defp resolve_by_convention(ref) do
    mod = Module.concat([Ezagent.E2E.Scenarios, Macro.camelize(ref)])

    if Code.ensure_loaded?(mod) and function_exported?(mod, :scenario, 0) do
      {:ok, mod}
    else
      {:error, {:unknown_scenario, ref, Map.keys(@scenarios)}}
    end
  end
end
