defmodule Mix.Tasks.Ezagent.E2e.Run do
  @shortdoc "Run an E2E scenario inside the running Ezagent node (#21 harness)"

  @moduledoc """
  Run an E2E scenario IN the live Ezagent runtime (scenarios seed via the production paths,
  which need the running node's DB + in-memory Kind state).

      mix ezagent.e2e.run scenario_0
      mix ezagent.e2e.run scenario_34 --up-to seed-relay   # tier-2 pre-trigger seeding

  Connects to the runtime the same way `mix ezagent` does (`EZAGENT_RUNTIME_NODE`,
  default `ezagent_runtime@127.0.0.1`).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, rest, _} = OptionParser.parse(argv, strict: [up_to: :string])

    case rest do
      [ref | _] ->
        runner_opts = if opts[:up_to], do: [up_to: opts[:up_to]], else: []
        dispatch(ref, runner_opts)

      [] ->
        IO.puts(:stderr, "usage: mix ezagent.e2e.run <scenario> [--up-to STEP]")
        exit({:shutdown, 2})
    end
  end

  defp dispatch(ref, runner_opts) do
    case Ezagent.Runtime.connect_as_cli() do
      {:ok, node} ->
        case :rpc.call(node, Ezagent.E2E.Run, :run_scenario, [ref, runner_opts], 180_000) do
          {:ok, ctx} ->
            IO.puts("scenario #{ref}: OK (ctx keys: #{inspect(Map.keys(ctx))})")

          {:error, reason} ->
            IO.puts(:stderr, "scenario #{ref}: FAILED — #{inspect(reason)}")
            exit({:shutdown, 1})

          {:badrpc, reason} ->
            IO.puts(:stderr, "scenario #{ref}: rpc failed — #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      {:error, _} ->
        IO.puts(
          :stderr,
          "error: Ezagent runtime not reachable at #{Ezagent.Runtime.runtime_node()} " <>
            "(start `mix phx.server` or set EZAGENT_RUNTIME_NODE)"
        )

        exit({:shutdown, 5})
    end
  end
end
