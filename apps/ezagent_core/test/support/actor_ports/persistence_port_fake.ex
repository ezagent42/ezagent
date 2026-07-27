defmodule Ezagent.Kind.Ports.PersistencePortFake do
  @moduledoc """
  Strict no-op `:test` fake for `Ezagent.Kind.Ports.PersistencePort` — lets
  the actor framework's own suite run spine-free (§3.4). Core's suite wires
  the real `Ezagent.Kind.Adapters.PersistenceAdapter`; this fake is for the
  future `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.PersistencePort

  @impl true
  def workspace_uri_for(_uri), do: {:error, :no_workspace}

  @impl true
  def scope_by_workspace(queryable, _workspace_uri), do: queryable

  @impl true
  def with_transient_retry(fun), do: fun.()
end
