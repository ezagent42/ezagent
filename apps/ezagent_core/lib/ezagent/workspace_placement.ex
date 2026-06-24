defmodule Ezagent.WorkspacePlacement do
  @moduledoc """
  Workspace ownership resolver facade.

  The initial implementation is local-only: every workspace is owned by the
  current runtime. Tests can inject a resolver to simulate non-owner runtimes.
  """

  alias Ezagent.WorkspacePlacement.LocalResolver

  @type owner :: term()

  @callback owner_of(URI.t()) :: {:ok, owner()} | {:error, term()}

  @spec owner_of(URI.t()) :: {:ok, owner()} | {:error, term()}
  def owner_of(%URI{} = workspace_uri), do: resolver().owner_of(workspace_uri)

  @spec local_owner?(URI.t()) :: boolean()
  def local_owner?(%URI{} = workspace_uri) do
    case owner_of(workspace_uri) do
      {:ok, owner} -> owner == Ezagent.RuntimeIdentity.current()
      {:error, _reason} -> false
    end
  end

  @spec resolver() :: module()
  def resolver do
    Application.get_env(:ezagent_core, __MODULE__, [])[:resolver] || LocalResolver
  end
end
