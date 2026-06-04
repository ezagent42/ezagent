defmodule Ezagent.E2E.Runner do
  @moduledoc """
  #21 PR-2 — execute a scenario's steps sequentially, threading `ctx`.

  Per-step order is **run → await → assert** (codex r2): `run` performs the action,
  `await` is the quiescence barrier (durable outcomes observed), `assert` is the
  correctness gate. Any failure stops the run and returns a labelled error
  (never silently continues). This PR runs WITHOUT layer caching; the resolver +
  layer publish/restore (PR-3) wrap this same per-step contract later — that's why
  `assert` already runs last, so PR-3 can publish a layer only on assert success.

  `opts`:
    * `:ctx`   — initial context map (default `%{}`).
    * `:up_to` — stop after this step (a 0-based index or a step `name`); used by tier 2
      to seed up to the pre-trigger state. Unknown name → `{:error, {:unknown_step, _}}`.
  """

  alias Ezagent.E2E.Scenario

  @type result :: {:ok, map()} | {:error, term()}

  @spec run(Scenario.t(), keyword()) :: result()
  def run(%Scenario{} = scenario, opts \\ []) do
    ctx0 = Keyword.get(opts, :ctx, %{})

    with {:ok, steps} <- limit_steps(scenario.steps, Keyword.get(opts, :up_to)) do
      run_steps(steps, ctx0, 0)
    end
  end

  defp run_steps([], ctx, _i), do: {:ok, ctx}

  defp run_steps([step | rest], ctx, i) do
    with {:ok, ctx2} <- do_run(step, ctx, i),
         :ok <- do_await(step, ctx2, i),
         :ok <- do_assert(step, ctx2, i) do
      run_steps(rest, ctx2, i + 1)
    end
  end

  defp do_run(step, ctx, i) do
    case step.run.(ctx) do
      {:ok, ctx2} when is_map(ctx2) -> {:ok, ctx2}
      {:error, reason} -> {:error, {:step_run_failed, step.name, i, reason}}
      other -> {:error, {:step_run_bad_return, step.name, i, other}}
    end
  end

  defp do_await(step, ctx, i) do
    case step.await.(ctx) do
      :ok -> :ok
      {:error, reason} -> {:error, {:step_await_pending, step.name, i, reason}}
      other -> {:error, {:step_await_bad_return, step.name, i, other}}
    end
  end

  defp do_assert(step, ctx, i) do
    case step.assert.(ctx) do
      :ok -> :ok
      {:error, reason} -> {:error, {:step_assert_failed, step.name, i, reason}}
      other -> {:error, {:step_assert_bad_return, step.name, i, other}}
    end
  end

  defp limit_steps(steps, nil), do: {:ok, steps}

  defp limit_steps(steps, idx) when is_integer(idx) and idx >= 0,
    do: {:ok, Enum.take(steps, idx + 1)}

  defp limit_steps(steps, name) when is_binary(name) do
    case Enum.find_index(steps, &(&1.name == name)) do
      nil -> {:error, {:unknown_step, name}}
      idx -> {:ok, Enum.take(steps, idx + 1)}
    end
  end
end
