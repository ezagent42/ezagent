defmodule Ezagent.Cap.AuthorityLoader do
  @moduledoc """
  Dependency-inversion boundary for loading an issuer's unforgeable held caps.

  Core owns the issue algorithm; the identity domain supplies the existing
  live-slice plus durable-row loader. Callers never pass authority caps into
  `Cap.issue/3`.
  """

  @callback read_held_caps(URI.t()) :: MapSet.t(Ezagent.Capability.t())
  @callback principal_fenced?(URI.t()) :: boolean()
end
