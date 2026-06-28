defmodule Ezagent.Agent.PackageSeedHook do
  @moduledoc """
  Domain-agent implementation of core's `Ezagent.Plugin.SeedHook` —
  seeds/retires a plugin-package's RECIPE seed-definitions into
  ConfigStore (plugin-package handoff pieces 2 + 4).

  Unlike `Ezagent.Agent.RoleSeedHook` (which skips in `:test` because
  boot-time seeding runs outside the sandbox), the package install call
  runs in the CALLER's sandbox — so seeding is unconditional and the
  retire is override-safe.

  ## Retire override-safety

  Retire deletes the recipe ConfigPointer ONLY if the pointed object's
  `source_turn_id` is still the seed's deterministic value (no tenant CR
  override has repointed it). An override survives an unload.
  """

  @behaviour Ezagent.Plugin.SeedHook

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{ConfigObject, ConfigPointer}
  alias EzagentCore.Repo

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
    ws = RecipeRegistry.system_workspace_uri()
    subject = RecipeRegistry.recipe_subject_uri(ws, name)
    pointer_id = ConfigPointer.id(RecipeRegistry.recipe_layer(), ws, subject, RecipeRegistry.recipe_key())

    case Repo.get(ConfigPointer, pointer_id) do
      nil ->
        :ok

      pointer ->
        # Override-safe: only retire if the pointed object is still the
        # seed (source_turn_id matches RecipeRegistry's deterministic
        # seed value). A CR override carries a different source_turn_id
        # and survives the unload.
        obj = Repo.get(ConfigObject, pointer.config_id)
        seed_turn = "role-seed:#{ws}:#{name}"

        if obj && obj.source_turn_id == seed_turn do
          Repo.delete(pointer)

          # Best-effort: also remove the now-orphan ConfigObject. A
          # tenant override would have repointed the pointer to a
          # different object, so this object is the seed's own.
          _ = Repo.delete(obj)
        end

        :ok
    end
  rescue
    _ -> :ok
  end

  def retire(:socialware, _name), do: :ok
end
