defmodule Ezagent.Kind.Ports.PersistencePort do
  @moduledoc """
  §3.4 PersistencePort — the actor framework's narrow persistence-policy
  surface, resolved via `Application.fetch_env!(:ezagent_actor, :persistence)`.

  Owner (core spine): `Ezagent.Persistence`. The core adapter
  (`Ezagent.Kind.Adapters.PersistenceAdapter`) delegates 1:1; callback types
  are deliberately loose (`term()`) so the port itself carries no upward
  compile edge. Moves with the framework to `apps/ezagent_actor`.
  """

  @doc """
  Derive the canonical `workspace://<name>` string for a Kind/entity URI.
  `{:error, :no_workspace}` for cross-cutting (`:any`-workspace) schemes.
  """
  @callback workspace_uri_for(uri :: term()) :: {:ok, String.t()} | {:error, :no_workspace}

  @doc "Scope an Ecto queryable to a single workspace (`%URI{}` or string)."
  @callback scope_by_workspace(queryable :: term(), workspace_uri :: term()) :: term()

  @doc "Run `fun` under the core transient-DB-error retry policy."
  @callback with_transient_retry(fun :: (-> result)) :: result when result: var
end
