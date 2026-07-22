defmodule Ezagent.DomainGit.D0BackendReuseGate.SensitiveCredential do
  @moduledoc false

  @enforce_keys [:value]
  @derive {Inspect, only: []}
  defstruct [:value]
end
