defmodule Ezagent.Kind.IngressCensus.Collector do
  @moduledoc """
  Test/census-context collector for `Ezagent.Kind.IngressCensus` events.

  Attaches a `:telemetry` handler to `[:ezagent, :kind, :ingress_census]`
  and accumulates the observed `{callback, class, shape}` tuples in a
  deduplicated `MapSet` held by a named `Agent`. Used ONLY by the
  env-var-gated census hooks in the actor/core `test_helper.exs`
  (`EZAGENT_INGRESS_CENSUS=1`) — it is never attached by production
  runtime code, and it is safe to attach when no suite is running (the
  handler is a no-op accumulator; `observed/0` on a non-started
  collector returns `[]`).

  This is ENUMERATION-phase tooling (report-only): the collected set is
  dumped to `_build/census/<app>_ingress_census.txt` by the
  `ExUnit.after_suite` hook and feeds `docs/notes/v5-use-side-ingress-census.md`.
  Nothing here gates, raises, or alters Kind runtime behavior.
  """

  use Agent

  @event [:ezagent, :kind, :ingress_census]
  @handler_id {__MODULE__, :census_handler}

  @doc """
  Start the accumulator Agent and attach the telemetry handler.

  Idempotent-enough for test-helper use: returns `{:error, _}` from
  `:telemetry.attach/4` if already attached rather than crashing.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, _pid} = Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
      _pid -> :ok
    end

    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, :no_config)
  end

  @doc "Detach the telemetry handler and stop the accumulator Agent."
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)

    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.stop(pid, :normal, 5_000)
    end

    :ok
  end

  @doc """
  The deduplicated, sorted list of observed `{callback, class, shape}`
  tuples. `[]` when the collector is not running.
  """
  @spec observed() :: [{atom(), atom(), term()}]
  def observed do
    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> pid |> Agent.get(& &1) |> MapSet.to_list() |> Enum.sort()
    end
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(
        _event,
        _measurements,
        %{callback: callback, class: class, shape: shape},
        _config
      ) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> Agent.update(__MODULE__, &MapSet.put(&1, {callback, class, shape}))
    end
  end
end
