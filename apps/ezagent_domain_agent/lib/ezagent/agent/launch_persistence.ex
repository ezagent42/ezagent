defmodule Ezagent.Agent.LaunchPersistence do
  @moduledoc false

  @callback before_transaction(map()) :: :ok
  @callback persist(module(), map()) :: {:ok, map()} | {:error, term()}
end
