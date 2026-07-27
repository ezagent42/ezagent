defmodule Ezagent.Kind.Adapters.SagaAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.SagaPort` (§3.4). Owns BOTH
  halves of the legacy soft-coupling that used to live in
  `Ezagent.Router.dispatch_saga/2`: the `Code.ensure_loaded?/1` +
  `function_exported?/3` probe AND the `is_struct/2` representation check —
  the actor side passes the saga value through UNINSPECTED and never names
  the `Ezagent.SagaRunner.Saga` type. Either failure returns
  `{:error, :saga_runner_not_loaded}` (byte-for-byte the old observable
  contract). STAYS in core when the framework moves to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.SagaPort

  require Logger

  @impl true
  def execute(saga, ctx) do
    runner_ready? =
      Code.ensure_loaded?(Ezagent.SagaRunner) and
        function_exported?(Ezagent.SagaRunner, :execute, 2)

    cond do
      not runner_ready? ->
        Logger.debug("Ezagent.Kind.Adapters.SagaAdapter: Ezagent.SagaRunner not loaded")
        {:error, :saga_runner_not_loaded}

      not is_struct(saga, Ezagent.SagaRunner.Saga) ->
        Logger.debug(
          "Ezagent.Kind.Adapters.SagaAdapter: non-saga input " <>
            "(#{inspect(saga)}); the runner cannot execute it"
        )

        {:error, :saga_runner_not_loaded}

      true ->
        Ezagent.SagaRunner.execute(saga, ctx)
    end
  end
end
