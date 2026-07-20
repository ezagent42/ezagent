defmodule Ezagent.ProviderConnection.RecoveryRetryRecorder do
  @moduledoc false

  alias EzagentCore.Repo

  def recover(operation, _now, observer) do
    attempts = Process.get({__MODULE__, operation.id}, 0)
    Process.put({__MODULE__, operation.id}, attempts + 1)
    send(observer, {:attempted, operation.id, attempts + 1})

    if operation.correlation_id == "retry-once" and attempts == 0 do
      {:error, :transient}
    else
      operation
      |> Ecto.Changeset.change(status: "finalized", next_recovery_at: nil)
      |> Repo.update!()

      :ok
    end
  end
end
