defmodule Ezagent.DomainGit.Diagnostics do
  @moduledoc """
  Non-effectful operational diagnostics for the Git domain.

  This surface reports provider ids and adapter modules only. It performs no
  authorization, credential resolution, or provider callback invocation.
  """

  alias Ezagent.DomainGit.AdapterRegistry

  @doc "Lists registered provider adapters in stable provider-id order."
  @spec list_adapters() ::
          {:ok, [%{provider_id: String.t(), module: module()}]}
          | {:error, :registry_unavailable}
  def list_adapters, do: AdapterRegistry.list_for_diagnostics()
end
