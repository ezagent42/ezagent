defmodule Ezagent.DomainGit.WorkspaceProvisionPort do
  @moduledoc """
  Closed contract for workspace provisioning implementations.

  Authorization remains with the Git task access action set. Implementations
  receive only validated task coordinates and cannot accept repository or local
  path choices from callers.
  """

  alias __MODULE__.Request

  @type operation :: :prepare | :cleanup
  @type result :: {:ok, map()} | {:error, term()}

  @callback prepare(Request.t()) :: result()
  @callback cleanup(Request.t()) :: result()
end
