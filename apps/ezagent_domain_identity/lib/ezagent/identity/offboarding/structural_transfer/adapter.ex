defmodule Ezagent.Identity.Offboarding.StructuralTransfer.Adapter do
  @moduledoc false

  @callback supports?(URI.t()) :: boolean()
  @callback transfer(URI.t(), URI.t()) :: :ok | {:error, term()}
end
