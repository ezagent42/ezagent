defmodule Ezagent.ProviderConnection.RecoveryRecorder do
  @moduledoc false

  alias EzagentCore.Repo

  def recover(operation, _now, observer) do
    send(observer, {:recovered, operation.operation_class, operation.id})

    operation
    |> Ecto.Changeset.change(
      status: "finalized",
      safe_error_code: nil,
      next_recovery_at: nil
    )
    |> Repo.update!()

    :ok
  end
end
