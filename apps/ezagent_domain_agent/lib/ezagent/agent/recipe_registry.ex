defmodule Ezagent.Agent.RecipeRegistry do
  @moduledoc """
  RecipeRegistry — `role name → recipe`, resolved **read-through over ConfigStore**
  (role-as-data, SPEC `docs/together/2026-06-27/specs/role-as-data-cr-governance.md`
  §3/§4).

  A **role** is a flavor-agnostic sandbox-content recipe (see `Ezagent.Agent.Recipe`)
  stored UNIFORMLY as a `ConfigObject`: `subject_uri = recipe:<name>` (a
  structured non-URI subject; workspace is a separate ConfigStore field),
  `key = "recipe"`, `body =` the recipe map. A built-in role is **not** a special
  code recipe — it is the SAME data shape as a user-authored role; only the
  *seeding origin* differs (§0).

  ## Read-through (ETS = cache, NOT authority — §3)

  `lookup/2` resolves from `Ezagent.Socialware.ConfigStore` (the durable
  authority), rehydrating via `Ezagent.Agent.Recipe.new/1` (the validation boundary), and
  caches the result in ETS keyed by `(ws, name)`. ETS is an
  invalidate-on-publish cache: the ONLY writer is `lookup/2` itself (lazy fill).
  **Boot does NOT populate ETS** — a `roles/0`-derived ETS entry as runtime
  authority is exactly what the elimination criterion (§7.2) forbids.

  Resolution (within caller workspace `ws`):

    1. ETS hit for `(ws, name)` → return cached `%Recipe{}`.
    2. else `ConfigStore.resolve("workspace", ws, "recipe:<name>", "recipe")`.
    3. if `:none` → fall back to `(system_ws, name)` (the cross-ws fallback that
       delivers "workspace-scoped + forkable": a tenant sees the system built-in
       until it forks its own; §3 OQ-2). This fallback lives HERE, not in
       `ConfigStore.resolve/4` (a single-tuple read).
    4. if still `:none` → `:error`.
    5. `{:ok, role} = Recipe.new(obj.body)`; cache `(ws, name) → role`; return.

  ## Seeding (§4)

  `seed_role_if_absent/2` writes the recipe as a ConfigObject in the SYSTEM
  workspace IFF no pointer yet exists for its `(ws, subject, "role")` — idempotent
  AND override-safe (a published tenant edit survives a reboot). `Ezagent.Plugin.boot/1`
  calls it for each `roles/0` recipe (prod/dev; skipped in `:test`, where tests
  seed explicitly inside their Ecto sandbox — same `test_env?` discipline as the
  identity admin/smtp seeds).

  ## Two-plugins-one-name collision vs. self-upgrade (#1223 M2 reflow)

  Seeding distinguishes TWO shapes that both present as "pointer exists, body
  differs":

    * a genuine SAME-BOOT collision — two DIFFERENT plugins claim the same role
      name with different bodies in ONE boot — still fails loud
      (`{:role_seed_collision, name}`), caught by the per-boot registry
      (`@boot_seed_key`); and
    * a CROSS-VERSION self-upgrade — a single plugin ships a NEW body of its OWN
      role and boots against a reflow-carried DB holding the OLD body under the
      deterministic seed `source_turn_id` — which UPGRADES (writes the new object
      + repoints) instead of colliding. Mirrors
      `DefinitionRegistry.seed_builtin_definition/2`. The upgrade write is
      idempotent under the entrypoint retry loop (a unique `source_turn_id` hit →
      `{:ok, :already_upgraded}`, same guard as #1235). A user/CR OVERRIDE (a
      non-seed-family `source_turn_id`) still survives untouched (`{:ok, :exists}`).

  The old runtime ETS raise is gone — immutability is the append-only ConfigObject
  + re-point.
  """

  alias Ezagent.Agent.Recipe
  alias Ezagent.Socialware.{ConfigObject, ConfigPointer, ConfigStore, ContentHash}

  @table :ezagent_role_registry

  # Per-boot in-memory {role_name → body_hash} registry (VM-global via
  # persistent_term). It keeps a genuine SAME-BOOT two-plugins-one-name collision
  # loud (§4.2) while letting a CROSS-VERSION reboot UPGRADE its own seed: a name
  # seeded THIS boot with a DIFFERENT body is a collision; a name whose only prior
  # body lives in a reflow-carried DB (a PRIOR boot) has no entry here → upgrade.
  # Lifetime == one VM boot; `reset_boot_seed_registry/0` (called per test by the
  # shared `EzagentCore.DataCase`) makes one test behave as one fresh boot.
  @boot_seed_key {__MODULE__, :boot_seed_hashes}

  # Fixed ConfigObject key per recipe subject (one recipe-recipe slice per role).
  @recipe_key "recipe"

  # Recipe-config lives on the `workspace` layer of the cascade (a role is a
  # workspace-scoped reusable recipe; user/session layers are not meaningful).
  @recipe_layer "workspace"

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc "The fixed ConfigObject `key` for a recipe subject."
  @spec recipe_key() :: String.t()
  def recipe_key, do: @recipe_key

  @doc "The ConfigStore `layer` a recipe subject lives on (`\"workspace\"`)."
  @spec recipe_layer() :: String.t()
  def recipe_layer, do: @recipe_layer

  @doc """
  The canonical system workspace URI string built-in roles are seeded under
  (`workspace://system`). One place; all built-ins live here and are reached by
  the `lookup/2` cross-ws fallback.
  """
  @spec system_workspace_uri() :: String.t()
  def system_workspace_uri, do: :system |> Ezagent.URI.workspace() |> URI.to_string()

  @doc """
  The recipe's OWN ConfigStore subject STRING for `name`: the structured
  non-URI identifier `recipe:<name>` (T1 project B — an opaque subject, NOT a
  `<scheme>://` URI; workspace is a SEPARATE ConfigStore field, so it is not
  embedded here). ConfigStore string-matches the subject exactly (§2.2). The
  `workspace_uri` argument is retained for call-site symmetry but is not part
  of the subject.
  """
  @spec recipe_subject_uri(String.t(), String.t()) :: String.t()
  def recipe_subject_uri(_workspace_uri, name)
      when is_binary(name) and name != "" do
    "recipe:#{name}"
  end

  @doc """
  Look up the validated `%Ezagent.Agent.Recipe{}` for a role name in the SYSTEM
  workspace (the built-in scope).

  Back-compat single-arg form: the pre-role-as-data callers
  (`OrchestratorBootstrap`, etc.) resolved built-ins by name only, so `lookup/1`
  resolves against the system workspace. New callers that carry a tenant
  workspace should use `lookup/2`.
  """
  @spec lookup(name :: String.t()) :: {:ok, Recipe.t()} | :error
  def lookup(name) when is_binary(name), do: lookup(system_workspace_uri(), name)

  @doc """
  Read-through lookup of the validated `%Ezagent.Agent.Recipe{}` for `(workspace, name)`.

  Returns `{:ok, role}` or `:error`. See the module doc for the resolution order
  (ETS cache → caller-ws ConfigStore → system-ws fallback → rehydrate).
  """
  @spec lookup(workspace_uri :: String.t() | URI.t(), name :: String.t()) ::
          {:ok, Recipe.t()} | :error
  def lookup(workspace_uri, name) when is_binary(name) do
    ws = uri_string(workspace_uri)

    case :ets.lookup(@table, {ws, name}) do
      [{{^ws, ^name}, %Recipe{} = role}] ->
        {:ok, role}

      [] ->
        resolve_through(ws, name)
    end
  end

  # Resolve from ConfigStore (caller ws → system-ws fallback), rehydrate via
  # Recipe.new/1, cache under (ws, name). This is the ONLY ETS writer.
  defp resolve_through(ws, name) do
    case resolve_object(ws, name) do
      {:ok, object} ->
        case Recipe.new(object.body) do
          {:ok, %Recipe{} = role} ->
            role = canonicalize_cap_values(role)
            :ets.insert(@table, {{ws, name}, role})
            {:ok, role}

          {:error, _reason} ->
            :error
        end

      :none ->
        :error
    end
  end

  # READ-THROUGH PARITY (SPEC §10 byte-identical invariant). `Recipe.new/1`
  # atomizes cap KEYS but deliberately leaves cap VALUES uncanonicalized
  # (deferring behavior-string→module / action-string→atom to `Recipe.CapMint`).
  # That is fine for an IN-MEMORY recipe (values arrive as atoms), but a recipe
  # READ BACK from ConfigStore round-trips its `requested_caps` values through
  # JSON → they return as STRINGS. To make a SEEDED role byte-identical to the
  # same recipe held in memory (so a built-in and a user role instantiate
  # identically — the core role-as-data invariant), canonicalize the cap VALUES
  # here at the rehydrate boundary, exactly as `Recipe.CapMint` does (idempotent:
  # CapMint re-canonicalizing an already-atom value is a no-op). Mirrors how
  # `behaviors` are decoded back to modules on rehydrate.
  defp canonicalize_cap_values(%Recipe{requested_caps: caps} = role) do
    %{role | requested_caps: Enum.map(caps, &canon_cap_values/1)}
  end

  defp canon_cap_values(cap) when is_map(cap) do
    cap
    |> maybe_canon(:behavior, &canon_module/1)
    |> maybe_canon(:action, &canon_atom/1)
  end

  defp maybe_canon(cap, key, fun) do
    case Map.fetch(cap, key) do
      {:ok, value} -> Map.put(cap, key, fun.(value))
      :error -> cap
    end
  end

  # string module-name → existing module atom (no atom-table growth); an
  # unresolved string is LEFT as-is so the downstream chokepoint rejects it.
  defp canon_module(s) when is_binary(s) do
    String.to_existing_atom(if String.starts_with?(s, "Elixir."), do: s, else: "Elixir." <> s)
  rescue
    ArgumentError -> s
  end

  defp canon_module(v), do: v

  defp canon_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> s
  end

  defp canon_atom(v), do: v

  # Caller-ws read, then the system-ws fallback (the ONE cross-ws wrinkle, §3).
  defp resolve_object(ws, name) do
    system_ws = system_workspace_uri()

    case ConfigStore.resolve(@recipe_layer, ws, recipe_subject_uri(ws, name), @recipe_key) do
      {:ok, object} ->
        {:ok, object}

      :none when ws != system_ws ->
        ConfigStore.resolve(
          @recipe_layer,
          system_ws,
          recipe_subject_uri(system_ws, name),
          @recipe_key
        )

      :none ->
        :none
    end
  end

  @doc """
  Invalidate the cached `%Recipe{}` for `(workspace, name)` — the seam a future
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
  Seed `recipe` as a role ConfigObject in the SYSTEM workspace — the upgrade-aware
  built-in seed path (§4.1/§4.2, mirroring `DefinitionRegistry.seed_builtin_definition/2`).

  Resolves the currently-pointed object for the recipe slot BEFORE writing:

  - No pointer yet → atomic seed-once-if-no-pointer (`{:ok, :seeded}`). The
    built-in is now config (first boot).
  - Pointer exists, SAME body (content-hash) → `{:ok, :exists}` (no-op).
    Idempotent reboot.
  - Pointer exists, DIFFERENT body from a SEED-FAMILY `source_turn_id`
    (`role-seed…`) → UPGRADE: writes the new object + repoints
    (`{:ok, :seeded}`; a retry that re-hits the unique upgrade turn id →
    `{:ok, :already_upgraded}`). This is the reflow self-upgrade path (#1223 M2):
    a plugin shipping a NEW body of its OWN role over a DB carrying the OLD one.
  - Pointer exists, DIFFERENT body from a NON-seed `source_turn_id` (a user/CR
    OVERRIDE) → `{:ok, :exists}`. The override SURVIVES. Override-safe.
  - Same name, DIFFERENT body seeded EARLIER THIS BOOT (two plugins) → `{:error,
    {:role_seed_collision, name}}` (loud; the per-boot registry discriminates a
    same-boot collision from a cross-version upgrade).

  Validates the recipe through `Recipe.new/1` (fail-loud on a malformed/flavor-
  carrying recipe) BEFORE any write. The recipe `body` is stored with `behaviors`
  as module-name STRINGS (JSON-safe; `Recipe.new/1` round-trips them on rehydrate).
  """
  @spec seed_role_if_absent(recipe :: map(), opts :: keyword()) ::
          {:ok, :seeded | :exists | :already_upgraded} | {:error, term()}
  def seed_role_if_absent(recipe, opts \\ []) when is_map(recipe) do
    name = recipe_name(recipe)

    with {:ok, %Recipe{}} <- validate_recipe(recipe) do
      ws = system_workspace_uri()
      subject = recipe_subject_uri(ws, name)
      actor = Keyword.get(opts, :actor_uri, default_seed_actor())
      body = recipe_body(recipe)
      new_hash = ContentHash.of(body)

      # Per-boot loudness guard (§4.2): a name already seeded THIS boot with a
      # DIFFERENT body is a genuine two-plugins-one-name collision, NOT a
      # cross-version upgrade (a reflow-carried OLD body has no per-boot entry).
      case boot_seed_collision(name, new_hash) do
        {:error, _} = collision ->
          collision

        :ok ->
          result = seed_or_upgrade(ws, subject, name, body, actor, new_hash)
          record_boot_seed(name, new_hash, result)
          result
      end
    end
  end

  # Resolve the current pointed object, then seed / no-op / upgrade / preserve.
  defp seed_or_upgrade(ws, subject, name, body, actor, new_hash) do
    case ConfigStore.resolve(@recipe_layer, ws, subject, @recipe_key) do
      :none ->
        ConfigStore.seed_object_if_no_pointer(%{
          layer: @recipe_layer,
          workspace_uri: ws,
          subject_uri: subject,
          key: @recipe_key,
          body: body,
          actor_uri: actor,
          source_turn_id: seed_source_turn_id(ws, name),
          collision_tag: {:role_seed_collision, name}
        })

      {:ok, %ConfigObject{} = pointed} ->
        cond do
          # `pointed.content_hash` is the stored column; `new_hash` is
          # `ContentHash.of(body)` — the SAME canonical (key-sorted, stringified)
          # hash, so a logically-identical body matches regardless of atom-vs-JSON
          # representation.
          pointed.content_hash == new_hash ->
            {:ok, :exists}

          seed_family_turn?(pointed.source_turn_id) ->
            upgrade_role(ws, subject, name, body, actor, new_hash)

          true ->
            # A user/CR override owns the pointer — never clobber it.
            {:ok, :exists}
        end
    end
  end

  # Write the new body + repoint (append-only), stamped with a hash-carrying
  # upgrade turn id so the write is idempotent under the entrypoint retry loop.
  defp upgrade_role(ws, subject, name, body, actor, new_hash) do
    ConfigStore.write_and_point(%{
      layer: @recipe_layer,
      workspace_uri: ws,
      subject_uri: subject,
      key: @recipe_key,
      body: body,
      actor_uri: actor,
      source_turn_id: upgrade_source_turn_id(ws, name, new_hash)
    })
    |> case do
      {:ok, _write_result} ->
        invalidate(ws, name)
        {:ok, :seeded}

      # Same guard as #1235: a prior boot already wrote this exact upgrade (the
      # unique `(workspace, subject, key, source_turn_id)` index) before a crash;
      # the retry re-hits the same turn id. Report idempotent success so the
      # entrypoint retry loop survives.
      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :source_turn_id) do
          invalidate(ws, name)
          {:ok, :already_upgraded}
        else
          {:error, {:role_seed_upgrade_failed, name, errors}}
        end

      {:error, reason} ->
        {:error, {:role_seed_upgrade_failed, name, reason}}
    end
  end

  @doc """
  Reset the per-boot role-seed registry — the in-memory `{name → body_hash}` map
  that keeps a same-boot two-plugins-one-name collision loud while letting a
  cross-version reboot UPGRADE. Its lifetime is one VM boot; the shared
  `EzagentCore.DataCase` calls this per test so one test behaves as one fresh boot
  (the DB rows roll back per test, but this VM-global map would otherwise leak
  across tests and spuriously collide fixed-name seeds). Idempotent.
  """
  @spec reset_boot_seed_registry() :: :ok
  def reset_boot_seed_registry do
    :persistent_term.erase(@boot_seed_key)
    :ok
  end

  defp boot_seed_collision(name, new_hash) do
    case Map.get(boot_seed_hashes(), name) do
      nil -> :ok
      ^new_hash -> :ok
      _different -> {:error, {:role_seed_collision, name}}
    end
  end

  defp record_boot_seed(_name, _hash, {:error, _}), do: :ok

  defp record_boot_seed(name, hash, {:ok, _}) do
    :persistent_term.put(@boot_seed_key, Map.put(boot_seed_hashes(), name, hash))
    :ok
  end

  defp boot_seed_hashes, do: :persistent_term.get(@boot_seed_key, %{})

  defp seed_source_turn_id(ws, name), do: "role-seed:#{ws}:#{name}"

  defp upgrade_source_turn_id(ws, name, hash), do: "role-seed-upgrade:#{ws}:#{name}:#{hash}"

  # A SEED-FAMILY provenance: the deterministic first-seed turn (`role-seed:…`) or
  # a built-in self-upgrade turn (`role-seed-upgrade:…`). A user/CR override
  # carries a DIFFERENT prefix (`override-…`, `cr-publish:…`, a fork/repoint turn),
  # so it is NOT seed-family and its pointer is never clobbered by a re-seed.
  defp seed_family_turn?(turn) when is_binary(turn), do: String.starts_with?(turn, "role-seed")
  defp seed_family_turn?(_), do: false

  @doc """
  Retire a seeded role — the override-safe reverse of
  `seed_role_if_absent/2`. Deletes the ConfigPointer + its ConfigObject
  ONLY if the pointed object is still SEED-FAMILY (its `source_turn_id`
  is the deterministic first-seed value OR a `role-seed-upgrade:…` self-upgrade
  turn); a tenant CR override carries a non-seed `source_turn_id` and SURVIVES
  the retire. Also invalidates
  the read-through ETS cache entry so a post-retire `lookup/1` misses.

  Used by the plugin-package UNLOAD path (`Ezagent.Agent.PackageSeedHook`).
  Idempotent (a never-seeded or already-retired role is a no-op).
  """
  @spec retire_role(String.t()) :: :ok
  def retire_role(name) when is_binary(name) do
    ws = system_workspace_uri()
    subject = recipe_subject_uri(ws, name)
    pointer_id = ConfigPointer.id(@recipe_layer, ws, subject, @recipe_key)

    case EzagentCore.Repo.get(ConfigPointer, pointer_id) do
      nil ->
        :ok

      pointer ->
        obj = EzagentCore.Repo.get(ConfigObject, pointer.config_id)

        # Delete only if the pointed object is still SEED-FAMILY (the first-seed
        # turn OR a built-in self-upgrade turn); a tenant CR override carries a
        # non-seed `source_turn_id` and SURVIVES the retire.
        if obj && seed_family_turn?(obj.source_turn_id) do
          EzagentCore.Repo.delete(pointer)
          _ = EzagentCore.Repo.delete(obj)
        end

        :ok
    end
  rescue
    _ -> :ok
  after
    # Invalidate the read-through ETS cache so a post-retire lookup misses
    # (otherwise the cached %Recipe{} keeps answering :ok after the DB row
    # is gone). Always runs — even if the DB delete was skipped (an override
    # survives, but the cache entry is stale relative to the now-different
    # pointed object, so re-resolution on next lookup is the honest state).
    :ets.delete(@table, {system_workspace_uri(), name})
    :ok
  end

  @doc """
  Validate a USER-AUTHORED (data-role) recipe — the SCRIPTLESS guard (OQ-1
  option (b), SPEC §5.3/§6.3).

  `script` is the ONE code-injection vector a role carries: it is operator-
  authored file content written into a py-agent's `config_dir` and bounded only
  by the execution sandbox, NOT by CapBAC. So a runtime/user-authored data-role
  (the CR path) may NOT introduce a `script` — this rejects a non-empty `script`
  fail-loud (`{:error, {:script_not_allowed_in_data_role, name}}`). A built-in /
  operator-seeded role MAY carry a `script` as trusted CODE — it flows through
  `seed_role_if_absent/2` (which uses `validate_recipe/1`, NOT this guard).

  This is the enforcement PRIMITIVE the next-phase `Ezagent.ActionSet.RoleGovernance`
  calls at `stage_item` so a script-carrying role-CR is rejected at the authoring
  boundary, BEFORE any inert object is staged. It also runs the full `Recipe.new/1`
  validation (flavor-field reject, cap-axis reject, behaviors-must-be-loaded), so
  every non-script invariant a built-in recipe satisfies a data-role must too.

  Returns `{:ok, %Recipe{}}` or `{:error, term()}`.
  """
  @spec validate_data_role_recipe(map()) :: {:ok, Recipe.t()} | {:error, term()}
  def validate_data_role_recipe(recipe) when is_map(recipe) do
    with {:ok, %Recipe{script: script} = role} <- validate_recipe(recipe) do
      if is_binary(script) and script != "" do
        {:error, {:script_not_allowed_in_data_role, recipe_name(recipe)}}
      else
        {:ok, role}
      end
    end
  end

  defp validate_recipe(recipe) do
    case Recipe.new(recipe) do
      {:ok, role} ->
        {:ok, role}

      {:error, reason} ->
        {:error, {:invalid_role_recipe, recipe_name(recipe), reason}}
    end
  end

  # The recipe body to persist: the recipe map, but with `behaviors` rendered as
  # module-name STRINGS (the JSON-safe form; atoms are not JSON map values).
  # ConfigStore stringifies KEYS; behavior VALUES must be strings too so they
  # round-trip and `Recipe.new/1` decodes them back to loaded modules.
  defp recipe_body(recipe) do
    behaviors = Map.get(recipe, :behaviors) || Map.get(recipe, "behaviors") || []
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
              "RecipeRegistry: a role recipe MUST carry a non-empty :name to be keyed; " <>
                "got #{inspect(other)}."
    end
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri
end
