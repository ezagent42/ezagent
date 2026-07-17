defmodule Ezagent.Agent.LaunchPostCommitPublisher do
  @moduledoc false

  @callback publish(map()) :: :ok | {:error, term()}
end
