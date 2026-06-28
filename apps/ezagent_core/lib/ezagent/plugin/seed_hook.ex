defmodule Ezagent.Plugin.SeedHook do
  @moduledoc """
  Registered hook for SEEDING a plugin-package's seed-definitions into
  ConfigStore at install, and RETIRING them at unload (plugin-package
  handoff pieces 2 + 4).

  This is the package-seed counterpart to `Ezagent.Plugin.RoleSeedHook`.
  `RoleSeedHook` seeds a plugin's `roles/0` declarations at boot (a
  core→domain_agent seam); THIS hook seeds the EXTRA seed-definitions a
  package manifest references (`seed_refs` — recipe / socialware-def
  JSON files in the package's `priv/`), at the explicit
  `Ezagent.PluginPackage.install/1` call. Unlike `RoleSeedHook`, it does
  NOT skip in `:test` — the install call runs in the caller's sandbox
  (e.g. a test's checked-out Ecto connection), so seeding is honest and
  observable.

  Core owns the package contract + the install orchestrator; the seed
  store (`Ezagent.Socialware.ConfigStore` + `RecipeRegistry` /
  `DefinitionRegistry`) lives downstream (`ezagent_domain_identity` /
  `ezagent_domain_agent` / `ezagent_domain_session`). So the downstream
  app registers an implementation here at boot; with no registered
  implementation, `seed/3` + `retire/2` are no-ops.

  ## Boot order is honest, not raced

  A plugin package's install runs AFTER the host has booted (the host
  must be up to accept a hot-load), so the downstream domain apps that
  register the impl are always started before any `install/1` call.
  """

  @hooks_key {__MODULE__, :hooks}

  @callback seed(kind :: :recipe, name :: String.t(), body :: map()) ::
              :ok | {:error, term()}

  @callback retire(kind :: :recipe, name :: String.t()) :: :ok

  @doc "Register a downstream seed-hook implementation."
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    hooks = hooks()
    :persistent_term.put(@hooks_key, Enum.uniq([module | hooks]))
    :ok
  end

  @doc """
  Seed a recipe definition `body` (decoded JSON map) under `name`
  through the registered hook(s). The first `{:error, _}` halts.

  `kind` is `:recipe` only (socialware-definition seeding is a future
  enhancement — a `:socialware` seed_ref is REJECTED at manifest parse
  time, not silently dropped here).
  """
  @spec seed(:recipe, String.t(), map()) :: :ok | {:error, term()}
  def seed(:recipe, name, body) when is_binary(name) and is_map(body) do
    invoke_hooks(:seed, [:recipe, name, body])
  end

  @doc """
  Retire the recipe seed definition `name` — the reverse of `seed/3`,
  used by the unload path. Override-safe (a tenant CR override survives;
  see the implementation). Idempotent.
  """
  @spec retire(:recipe, String.t()) :: :ok
  def retire(:recipe, name) when is_binary(name) do
    invoke_hooks(:retire, [:recipe, name])
    :ok
  end

  defp invoke_hooks(function, args) do
    Enum.reduce_while(hooks(), :ok, fn module, :ok ->
      case invoke(module, function, args) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:invalid_seed_hook_return, module, function, other}}}
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
