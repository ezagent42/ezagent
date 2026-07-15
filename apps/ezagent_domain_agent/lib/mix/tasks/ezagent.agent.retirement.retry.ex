defmodule Mix.Tasks.Ezagent.Agent.Retirement.Retry do
  @shortdoc "Retry pending Agent retirement cleanup obligations"

  @moduledoc """
  Retries one durable Agent retirement obligation, or a due batch.

      mix ezagent.agent.retirement.retry 123
      mix ezagent.agent.retirement.retry --all
  """

  use Mix.Task

  alias Ezagent.Agent.RetirementSweeper

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["--all"] ->
        RetirementSweeper.run_due()
        |> Enum.each(&report/1)

      [id] ->
        case Integer.parse(id) do
          {parsed, ""} when parsed > 0 ->
            case RetirementSweeper.retry(parsed, operator: true) do
              {:ok, :resolved} ->
                report({parsed, {:ok, :resolved}})

              {:error, reason} ->
                Mix.raise("obligation #{parsed} retry failed: #{inspect(reason)}")
            end

          _ ->
            Mix.raise("obligation id must be a positive integer")
        end

      _ ->
        Mix.raise("usage: mix ezagent.agent.retirement.retry ID | --all")
    end
  end

  defp report({id, {:ok, :resolved}}), do: Mix.shell().info("resolved obligation #{id}")

  defp report({id, {:error, reason}}),
    do: Mix.shell().error("obligation #{id} remains pending: #{inspect(reason)}")
end
