defmodule Ezagent.Kind.Adapters.PersistenceAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.PersistencePort` (§3.4) —
  delegates 1:1 to the `Ezagent.Persistence` spine. STAYS in core when the
  framework moves to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.PersistencePort

  @impl true
  def workspace_uri_for(uri), do: Ezagent.Persistence.workspace_uri_for(uri)

  @impl true
  def scope_by_workspace(queryable, workspace_uri),
    do: Ezagent.Persistence.scope_by_workspace(queryable, workspace_uri)

  @impl true
  def with_transient_retry(fun), do: Ezagent.Persistence.TransientRetry.with_retry(fun)
end
