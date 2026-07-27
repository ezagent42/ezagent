defmodule Ezagent.Kind.Ports.SagaPort do
  @moduledoc """
  §3.4 SagaPort — saga execution for the actor framework, resolved via
  `Application.get_env(:ezagent_actor, :saga, :not_configured)`.

  Owner (core spine): `Ezagent.SagaRunner`. The saga value crosses as an
  OPAQUE `term()` — actor code never names the Saga type; the core adapter
  (`Ezagent.Kind.Adapters.SagaAdapter`) owns BOTH the `Code.ensure_loaded?/1`
  runner probe AND the `is_struct/2` representation check, returning
  `{:error, :saga_runner_not_loaded}` for either failure. The port's
  `:not_configured` default replaces the legacy soft-coupling. Moves with
  the framework to `apps/ezagent_actor`.
  """

  @doc """
  Execute a saga. `{:ok, result}` on success;
  `{:error, :saga_runner_not_loaded}` when the runner cannot run the input
  (not loaded, or not a saga representation it knows); otherwise the
  runner's own error shape.
  """
  @callback execute(saga :: term(), ctx :: map()) :: term()
end
