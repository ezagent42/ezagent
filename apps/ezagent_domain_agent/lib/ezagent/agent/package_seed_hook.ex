defmodule Ezagent.Agent.PackageSeedHook do
  @moduledoc """
  Domain-agent implementation of core's `Ezagent.Plugin.SeedHook` —
  seeds/retires a plugin-package's RECIPE seed-definitions into
  ConfigStore (plugin-package handoff pieces 2 + 4).

  Unlike `Ezagent.Agent.RoleSeedHook` (which skips in `:test` because
  boot-time seeding runs outside the sandbox), the package install call
  runs in the CALLER's sandbox — so seeding is unconditional and the
  retire is override-safe + cache-invalidating.
  """

  @behaviour Ezagent.Plugin.SeedHook

  alias Ezagent.Agent.RecipeRegistry

  @impl true
  def seed(:recipe, name, body) when is_binary(name) and is_map(body) do
    recipe = Map.put(body, "name", name)

    case RecipeRegistry.seed_role_if_absent(recipe) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def seed(:socialware, _name, _body), do: :ok

  @impl true
  def retire(:recipe, name) when is_binary(name) do
    RecipeRegistry.retire_role(name)
  end

  def retire(:socialware, _name), do: :ok
end
