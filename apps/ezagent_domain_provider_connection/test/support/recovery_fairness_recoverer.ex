defmodule Ezagent.ProviderConnection.RecoveryFairnessRecoverer do
  @moduledoc false

  import Ecto.Query

  alias Ezagent.ProviderConnection.Operation
  alias EzagentCore.Repo

  def recover(operation, _now, observer) do
    send(observer, {:attempted, operation.correlation_id})

    case operation.correlation_id do
      "clock-advance-failure" = correlation_id ->
        send(observer, {:advance_clock, self(), correlation_id})

        receive do
          {:clock_advanced, ^correlation_id} -> {:error, :backend_unavailable}
        end

      "stage-advance-failure" ->
        Operation
        |> where([row], row.id == ^operation.id and row.status == ^operation.status)
        |> Repo.update_all(set: [status: "backend_committed"])

        {:error, :backend_unavailable}

      "fenced-success" ->
        Operation
        |> where([row], row.id == ^operation.id and row.status == ^operation.status)
        |> Repo.update_all(set: [status: "fenced", safe_error_code: "connection_terminal"])

        :ok

      "poison" ->
        {:error, {:private_backend_reason, "credential=must-not-leak"}}

      "crash" ->
        raise "credential=must-not-leak"

      _success ->
        Operation
        |> where([row], row.id == ^operation.id)
        |> Repo.update_all(
          set: [
            status: "finalized",
            next_recovery_at: nil,
            last_recovery_error_code: nil
          ]
        )

        :ok
    end
  end
end
