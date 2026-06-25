defmodule Ezagent.RoleRegistry do
  @moduledoc """
  RoleRegistry — declarative `role name → recipe` map (role-foundation RF-4).

  A **role** is a flavor-agnostic sandbox-content recipe (see `Ezagent.Role`).
  Each plugin declares its built-in roles via the optional `roles/0` plugin
  callback (a list of recipe MAPS — the `OrchestratorRole.recipe/0` exemplar);
  `Ezagent.Plugin.boot/1` registers each one here. A registered role is then
  looked up **by name** at materialization (`Ezagent.Role.Compose`).

  This is the code-seed registry the design (§2.1) endorses for built-in roles.
  The forkable, persisted `template://<ws>/role/<name>` Template subtype is a
  documented follow-up.

  ## Placement (core, next to `Ezagent.Role`)

  `Ezagent.Role`, `Ezagent.Role.Compose`, and `Ezagent.Role.CapMint` all live
  in `ezagent_core`, and `register/1` validates a recipe through
  `Ezagent.Role.new/1` — so the registry lives here too (no cross-app dep). The
  table is owned by `EzagentCore.EtsOwner` (in its `@tables` list), so the
  publish loop in `Ezagent.Plugin.boot/1` (also in core) calls `register/1`
  **directly** — no publish-hook indirection is needed (the analogous
  downstream-app flavor registry needs one only because it lives downstream of
  `boot/1`).

  ## ETS layout

  `:ezagent_role_registry` `:set` table. Key is the role NAME (string); value is
  the validated `%Ezagent.Role{}` recipe struct.
  """

  @table :ezagent_role_registry

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Register a role from a recipe MAP (the `roles/0` declaration shape — what
  `Ezagent.Role.new/1` consumes).

  The recipe MUST carry a non-empty `:name` (the registry is keyed by it) — a
  nameless recipe cannot be keyed, so it is rejected fail-loud. The map is
  validated through `Ezagent.Role.new/1`; an invalid recipe raises.

  Idempotent for an identical recipe under the same name. A DIFFERENT recipe
  under an already-registered name is a real bug — raises `ArgumentError` (two
  plugins must not claim the same role name).
  """
  @spec register(map()) :: :ok
  def register(recipe) when is_map(recipe) do
    name = recipe_name(recipe)

    role =
      case Ezagent.Role.new(recipe) do
        {:ok, role} ->
          role

        {:error, reason} ->
          raise ArgumentError,
                "RoleRegistry: recipe #{inspect(name)} rejected by Ezagent.Role.new/1 — " <>
                  "#{inspect(reason)}."
      end

    case :ets.lookup(@table, name) do
      [{^name, ^role}] ->
        :ok

      [{^name, existing}] ->
        raise ArgumentError,
              "RoleRegistry: role #{inspect(name)} already registered as " <>
                "#{inspect(existing)}; cannot re-register as #{inspect(role)}. " <>
                "Two plugins must not claim the same role name."

      [] ->
        :ets.insert(@table, {name, role})
        :ok
    end
  end

  @doc """
  Look up the validated `%Ezagent.Role{}` recipe for a role name.

  Returns `{:ok, recipe}` or `:error`.
  """
  @spec lookup(name :: String.t()) :: {:ok, Ezagent.Role.t()} | :error
  def lookup(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, role}] -> {:ok, role}
      [] -> :error
    end
  end

  @doc "List every registered `{name, recipe}` pair — for debug / admin."
  @spec list_all() :: [{String.t(), Ezagent.Role.t()}]
  def list_all, do: :ets.tab2list(@table)

  # The registry is keyed by name, so a recipe with no name (atom or persisted
  # string key) cannot be registered — fail loud, not silent-drop.
  defp recipe_name(recipe) do
    case Map.get(recipe, :name) || Map.get(recipe, "name") do
      name when is_binary(name) and name != "" ->
        name

      other ->
        raise ArgumentError,
              "RoleRegistry: a role recipe MUST carry a non-empty :name to be keyed; " <>
                "got #{inspect(other)}."
    end
  end
end
