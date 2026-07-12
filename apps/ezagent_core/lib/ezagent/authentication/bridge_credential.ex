defmodule Ezagent.Authentication.BridgeCredential do
  @moduledoc "Connection-bound bridge credential presented to the unified authN resolver."

  @enforce_keys [:token, :principal]
  defstruct [:token, :principal]

  @type t :: %__MODULE__{token: String.t(), principal: URI.t()}
end
