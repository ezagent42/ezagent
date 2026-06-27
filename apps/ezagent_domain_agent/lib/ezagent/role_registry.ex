defmodule Ezagent.RoleRegistry do
  @moduledoc """
  RoleRegistry — `role name → recipe`, resolved **read-through over ConfigStore**
  (role-as-data, SPEC `docs/together/2026-06-27/specs/role-as-data-cr-governance.md`
  §3/§4).

  A **role** is a flavor-agnostic sandbox-content recipe (see `Ezagent.Role`)
  stored UNIFORMLY as a `ConfigObject`: `subject_uri = config://<ws>/role/<name>`,
  `key = "role"`, `body =` the recipe map. A built-in role is **not** a special
  code recipe — it is the SAME data shape as a user-authored role; only the
  *seeding origin* differs (§0).

  ## Read-through (ETS = cache, NOT authority — §3)

  `lookup/2` resolves from `Ezagent.Socialware.ConfigStore` (the durable
  authority), rehydrating via `Ezagent.Role.new/1` (the validation boundary), and
  caches the result in ETS keyed by `(ws, name)`. ETS is an
  invalidate-on-publish cache: the ONLY writer is `lookup/2` itself (lazy fill).
  **Boot does NOT populate ETS** — a `roles/0`-derived ETS entry as runtime
  authority is exactly what the elimination criterion (§7.2) forbids.

  Resolution (within caller workspace `ws`):

    1. ETS hit for `(ws, name)` → return cached `%Role{}`.
    2. else `ConfigStore.resolve("workspace", ws, config://<ws>/role/<name>, "role")`.
    3. if `:none` → fall back to `(system_ws, name)` (the cross-ws fallback that
       delivers "workspace-scoped + forkable": a tenant sees the system built-in
       until it forks its own; §3 OQ-2). This fallback lives HERE, not in
       `ConfigStore.resolve/4` (a single-tuple read).
    4. if still `:none` → `:error`.
    5. `{:ok, role} = Role.new(obj.body)`; cache `(ws, name) → role`; return.

  ## Seeding (§4)

  `seed_role_if_absent/2` writes the recipe as a ConfigObject in the SYSTEM
  workspace IFF no pointer yet exists for its `(ws, subject, "role")` — idempotent
  AND override-safe (a published tenant edit survives a reboot). `Ezagent.Plugin.boot/1`
  calls it for each `roles/0` recipe (prod/dev; skipped in `:test`, where tests
  seed explicitly inside their Ecto sandbox — same `test_env?` discipline as the
  identity admin/smtp seeds).

  ## Two-plugins-one-name collision

  Preserved as a SEED-time check (§4.2): a second plugin seeding the same role
  name in the system ws with a DIFFERENT body fails loud
  (`{:role_seed_collision, name}`). The old runtime ETS raise is gone —
  immutability is now the append-only ConfigObject + re-point.
  """

  alias Ezagent.Role
  alias Ezagent.Socialware.ConfigStore

  @table :ezagent_role_registry

  # Fixed ConfigObject key per role subject (one role-recipe slice per role).
  @role_key "role"

  # Role-config lives on the `workspace` layer of the cascade (a role is a
  # workspace-scoped reusable recipe; user/session layers are not meaningful).
  @role_layer "workspace"

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc "The fixed ConfigObject `key` for a role subject."
  @spec role_key() :: String.t()
  def role_key, do: @role_key

  @doc """
  The canonical system workspace URI string built-in roles are seeded under
  (`workspace://system`). One place; all built-ins live here and are reached by
  the `lookup/2` cross-ws fallback.
  """
  @spec system_workspace_uri() :: String.t()
  def system_workspace_uri, do: :system |> Ezagent.URI.workspace() |> URI.to_string()

  @doc """
  The role's OWN ConfigStore subject STRING for `(workspace, name)`:
  `config://<ws>/role/<name>` (workspace-first to match the `entity://`
  convention, but NOT an `entity://` principal — `Ezagent.URI.entity/3` rejects
  non-`user|agent|worker` types; ConfigStore string-matches this opaquely; §2.2).
  """
  @spec role_subject_uri(String.t(), String.t()) :: String.t()
  def role_subject_uri(workspace_uri, name)
      when is_binary(workspace_uri) and is_binary(name) and name != "" do
    "config://#{workspace_host(workspace_uri)}/role/#{name}"
  end

  @doc """
  Look up the validated `%Ezagent.Role{}` for a role name in the SYSTEM
  workspace (the built-in scope).

  Back-compat single-arg form: the pre-role-as-data callers
  (`OrchestratorBootstrap`, etc.) resolved built-ins by name only, so `lookup/1`
  resolves against the system workspace. New callers that carry a tenant
  workspace should use `lookup/2`.
  """
  @spec lookup(name :: String.t()) :: {:ok, Role.t()} | :error
  def lookup(name) when is_binary(name), do: lookup(system_workspace_uri(), name)

  @doc """
  Read-through lookup of the validated `%Ezagent.Role{}` for `(workspace, name)`.

  Returns `{:ok, role}` or `:error`. See the module doc for the resolution order
  (ETS cache → caller-ws ConfigStore → system-ws fallback → rehydrate).
  """
  @spec lookup(workspace_uri :: String.t() | URI.t(), name :: String.t()) ::
          {:ok, Role.t()} | :error
  def lookup(workspace_uri, name) when is_binary(name) do
    ws = uri_string(workspace_uri)

    case :ets.lookup(@table, {ws, name}) do
      [{{^ws, ^name}, %Role{} = role}] ->
        {:ok, role}

      [] ->
        resolve_through(ws, name)
    end
  end

  # Resolve from ConfigStore (caller ws → system-ws fallback), rehydrate via
  # Role.new/1, cache under (ws, name). This is the ONLY ETS writer.
  defp resolve_through(ws, name) do
    case resolve_object(ws, name) do
      {:ok, object} ->
        case Role.new(object.body) do
          {:ok, %Role{} = role} ->
            :ets.insert(@table, {{ws, name}, role})
            {:ok, role}

          {:error, _reason} ->
            :error
        end

      :none ->
        :error
    end
  end

  # Caller-ws read, then the system-ws fallback (the ONE cross-ws wrinkle, §3).
  defp resolve_object(ws, name) do
    system_ws = system_workspace_uri()

    case ConfigStore.resolve(@role_layer, ws, role_subject_uri(ws, name), @role_key) do
      {:ok, object} ->
        {:ok, object}

      :none when ws != system_ws ->
        ConfigStore.resolve(
          @role_layer,
          system_ws,
          role_subject_uri(system_ws, name),
          @role_key
        )

      :none ->
        :none
    end
  end

  @doc """
  Invalidate the cached `%Role{}` for `(workspace, name)` — the seam a future
  role-CR publish/rollback emits so the next `lookup/2` re-resolves from
  ConfigStore. Idempotent (deleting an absent key is a no-op).
  """
  @spec invalidate(workspace_uri :: String.t() | URI.t(), name :: String.t()) :: :ok
  def invalidate(workspace_uri, name) when is_binary(name) do
    :ets.delete(@table, {uri_string(workspace_uri), name})
    :ok
  end

  @doc """
  Flush the ENTIRE role cache — used by the elimination invariant ("flush ETS →
  `lookup` STILL returns the built-in", proving lookup resolves from ConfigStore
  and not a surviving ETS write) and by tests.
  """
  @spec flush_cache() :: :ok
  def flush_cache do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Seed `recipe` as a role ConfigObject in the SYSTEM workspace IFF no pointer yet
  exists for its `(system_ws, config://<ws>/role/<name>, "role")` — the atomic
  seed-once-if-no-pointer primitive (§4.1/§4.2).

  - First boot: no pointer → writes object + points. The built-in is now config.
  - Reboot, unchanged: pointer exists → `{:ok, :exists}` (no-op). Idempotent.
  - Reboot after a published override: pointer exists (aimed at the override) →
    `{:ok, :exists}`. The override SURVIVES the restart. Override-safe.
  - Two plugins, same name, DIFFERENT body in the system ws → `{:error,
    {:role_seed_collision, name}}` (loud, the moved boot-collision guard).

  Validates the recipe through `Role.new/1` (fail-loud on a malformed/flavor-
  carrying recipe) BEFORE any write. The recipe `body` is stored with `behaviors`
  as module-name STRINGS (JSON-safe; `Role.new/1` round-trips them on rehydrate).
  """
  @spec seed_role_if_absent(recipe :: map(), opts :: keyword()) ::
          {:ok, :seeded | :exists} | {:error, term()}
  def seed_role_if_absent(recipe, opts \\ []) when is_map(recipe) do
    name = recipe_name(recipe)

    with {:ok, %Role{}} <- validate_recipe(recipe) do
      ws = system_workspace_uri()
      subject = role_subject_uri(ws, name)
      actor = Keyword.get(opts, :actor_uri, default_seed_actor())
      body = recipe_body(recipe)

      ConfigStore.seed_object_if_no_pointer(%{
        layer: @role_layer,
        workspace_uri: ws,
        subject_uri: subject,
        key: @role_key,
        body: body,
        actor_uri: actor,
        source_turn_id: "role-seed:#{ws}:#{name}",
        collision_tag: {:role_seed_collision, name}
      })
    end
  end

  defp validate_recipe(recipe) do
    case Role.new(recipe) do
      {:ok, role} ->
        {:ok, role}

      {:error, reason} ->
        {:error, {:invalid_role_recipe, recipe_name(recipe), reason}}
    end
  end

  # The recipe body to persist: the recipe map, but with `behaviors` rendered as
  # module-name STRINGS (the JSON-safe form; atoms are not JSON map values).
  # ConfigStore stringifies KEYS; behavior VALUES must be strings too so they
  # round-trip and `Role.new/1` decodes them back to loaded modules.
  defp recipe_body(recipe) do
    behaviors = get(recipe, :behaviors, [])
    Map.put(recipe, :behaviors, Enum.map(behaviors, &behavior_string/1))
  end

  defp behavior_string(mod) when is_atom(mod), do: Atom.to_string(mod)
  defp behavior_string(s) when is_binary(s), do: s

  defp default_seed_actor, do: Ezagent.URI.user(:system, :admin) |> URI.to_string()

  # The registry is keyed by name, so a recipe with no name (atom or persisted
  # string key) cannot be keyed — fail loud, not silent-drop.
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

  defp get(recipe, atom_key, default) do
    case Map.fetch(recipe, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(recipe, Atom.to_string(atom_key), default)
    end
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri

  # The "host" segment of a workspace URI — `workspace://system` → "system".
  defp workspace_host(workspace_uri) do
    case Ezagent.URI.new!(workspace_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      %URI{path: "/" <> rest} -> rest
      _ -> workspace_uri
    end
  end
end
