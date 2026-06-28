defmodule Ezagent.Plugin.RoleSeedHook do
  @moduledoc """
  Registered hook for SEEDING `roles/0` declarations as role ConfigObjects
  (role-as-data, SPEC §4).

  Core owns the plugin contract and collects `roles/0` declarations, but the
  role store (`Ezagent.Agent.RecipeRegistry` read-through over
  `Ezagent.Socialware.ConfigStore`) is an `ezagent_domain_agent` concern — it
  cannot live in core (core has no umbrella deps; ConfigStore is in
  `ezagent_domain_identity`). So, exactly like `Ezagent.Plugin.FlavorPublishHook`,
  `ezagent_domain_agent` registers a downstream implementation here at boot;
  with no registered implementation, `seed_role/1` is a no-op.

  ## Boot order is honest, not raced

  Every plugin that declares `roles/0` (cc, py, kanban, kb) compile-deps
  `ezagent_domain_agent`, so domain_agent's `start/2` (which registers the impl)
  always runs BEFORE any such plugin's `Ezagent.Plugin.boot/1` (which calls
  `seed_role/1`). A plugin with no role decls never calls this; a plugin that
  does is guaranteed an impl is registered. The `:test` skip lives in the
  IMPLEMENTATION (the DB writer decides to skip) — this seam is pure dispatch
  and knows nothing about the env.
  """

  @hooks_key {__MODULE__, :hooks}

  @callback seed_role(recipe :: map()) :: :ok | {:error, term()}

  @doc "Register a downstream role-seed hook implementation."
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    hooks = hooks()
    :persistent_term.put(@hooks_key, Enum.uniq([module | hooks]))
    :ok
  end

  @doc false
  @spec seed_role(map()) :: :ok | {:error, term()}
  def seed_role(recipe) when is_map(recipe) do
    invoke_hooks(:seed_role, [recipe])
  end

  @doc """
  Seed every recipe in `recipes` (a plugin's `roles/0`) through the hook,
  raising loud (`ArgumentError`) on the first `{:error, _}` — the boot contract
  `Ezagent.Plugin.boot/1` uses. A divergent-body collision (two plugins, same
  role name) surfaces here.
  """
  @spec seed_roles(module(), [map()]) :: :ok
  def seed_roles(plugin_module, recipes) when is_atom(plugin_module) and is_list(recipes) do
    Enum.each(recipes, fn recipe ->
      case seed_role(recipe) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError,
                "#{inspect(plugin_module)}: RoleSeedHook rejected a roles/0 recipe — " <>
                  "#{inspect(reason)}."
      end
    end)
  end

  defp invoke_hooks(function, args) do
    Enum.reduce_while(hooks(), :ok, fn module, :ok ->
      case invoke(module, function, args) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:invalid_role_seed_hook_return, module, function, other}}}
      end
    end)
  end

  defp invoke(module, function, args) do
    arity = length(args)

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      apply(module, function, args)
    else
      :ok
    end
  end

  defp hooks do
    :persistent_term.get(@hooks_key, [])
  end
end
