defmodule Ezagent.Agent.RecipeBehaviorFold do
  @moduledoc """
  Shared recipe × flavor behavior composition for agent materialization paths.

  The caller owns recipe lookup because lookup scope differs by path. This module
  owns the invariant that a concrete `{recipe, flavor}` pair folds through one
  composition seam before any path materializes an agent.
  """

  alias Ezagent.Agent.Recipe

  @doc """
  Fold a validated recipe with a flavor declaration into the materialized recipe
  shape used by both direct agent-create and template materialization.
  """
  @spec fold(Recipe.t(), String.t()) ::
          {:ok, Recipe.Compose.materialized()} | {:error, {:unknown_flavor_for_role, String.t()}}
  def fold(%Recipe{} = recipe, flavor) when is_binary(flavor) do
    with {:ok, decl} <- lookup_flavor_decl(flavor) do
      flavor_behaviors = flavor_behavior_set(decl)
      {:ok, Recipe.Compose.materialize(recipe, %{flavor_behaviors: flavor_behaviors})}
    end
  end

  @doc false
  @spec lookup_flavor_decl(String.t()) ::
          {:ok, map()} | {:error, {:unknown_flavor_for_role, String.t()}}
  def lookup_flavor_decl(flavor) do
    case Ezagent.AgentFlavorRegistry.lookup(flavor) do
      {:ok, decl} -> {:ok, decl}
      :error -> {:error, {:unknown_flavor_for_role, flavor}}
    end
  end

  # The flavor's complete per-instance behavior set: the flavor's declared
  # `:instance_behaviors` thunk when present, else the Kind's nil-capture default.
  defp flavor_behavior_set(decl) do
    case Map.get(decl, :instance_behaviors) do
      thunk when is_function(thunk, 0) -> thunk.()
      _ -> Ezagent.Kind.nil_capture_behavior_set(Map.fetch!(decl, :kind))
    end
  end
end
