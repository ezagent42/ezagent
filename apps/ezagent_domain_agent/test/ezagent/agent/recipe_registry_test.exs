defmodule Ezagent.Agent.RecipeRegistryTest do
  @moduledoc """
  role-as-data (SPEC §3/§4/§5.3) — `Ezagent.Agent.RecipeRegistry` read-through over
  `Ezagent.Socialware.ConfigStore`, idempotent + override-safe seeding, the
  cross-workspace fallback, and the scriptless data-role guard (OQ-1=b).

  These are the SPEC §8 deltas: role-is-its-own-subject, lookup read-through
  parity (ETS = cache, ConfigStore = authority), seed idempotency/override-
  safety/collision, and the script authoring gate.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{ConfigObject, ConfigStore, ContentHash}

  setup do
    # Each test uses a UNIQUE role name so the shared ETS cache + the appended
    # ConfigObject rows never collide across tests.
    name = "role-test-#{System.unique_integer([:positive])}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)
    %{name: name, system_ws: RecipeRegistry.system_workspace_uri()}
  end

  defp role_subject(ws, name), do: RecipeRegistry.recipe_subject_uri(ws, name)

  defp resolve_role_object(ws, name) do
    ConfigStore.resolve("workspace", ws, role_subject(ws, name), RecipeRegistry.recipe_key())
  end

  # Reproduce a PRIOR-boot DB row: `prompt` written with the DETERMINISTIC seed
  # source_turn_id, DIRECTLY (bypasses seed_role_if_absent so the per-boot registry
  # stays empty — exactly a reflow-carried DB from an EARLIER deploy/boot).
  defp seed_prior_boot!(ws, name, prompt) do
    {:ok, %{object: object}} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: ws,
        subject_uri: role_subject(ws, name),
        key: "recipe",
        body: %{"name" => name, "prompt" => prompt},
        actor_uri: "entity://system/user/admin",
        source_turn_id: "role-seed:#{ws}:#{name}"
      })

    object
  end

  # ---- §8.1 role is its OWN subject; seed writes CONFIG (not just ETS) -------

  test "seed_role_if_absent writes a role ConfigObject resolvable at subject recipe:<name>",
       %{name: name, system_ws: ws} do
    assert {:ok, :seeded} =
             RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "hello", skills: ["s1"]})

    # The seed wrote a real ConfigObject (proves config, not ETS).
    assert {:ok, %ConfigObject{body: body, subject_uri: subj, key: "recipe"}} =
             resolve_role_object(ws, name)

    assert subj == role_subject(ws, name)
    assert body["name"] == name
    assert body["prompt"] == "hello"
    assert body["skills"] == ["s1"]
  end

  # ---- §8.2 lookup read-through (ETS flushed → resolves from ConfigStore) ----

  test "lookup resolves read-through from ConfigStore after the ETS cache is flushed",
       %{name: name, system_ws: ws} do
    {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "p"})

    # Flush the ENTIRE cache — proves the next lookup resolves from ConfigStore,
    # not a surviving ETS write (the elimination invariant, §7.2).
    :ok = RecipeRegistry.flush_cache()

    assert {:ok, %Ezagent.Agent.Recipe{name: ^name, prompt: "p"}} = RecipeRegistry.lookup(ws, name)
  end

  test "lookup parity: read-through role == the seeded recipe (rehydrated via Recipe.new/1)",
       %{name: name, system_ws: ws} do
    {:ok, expected} = Ezagent.Agent.Recipe.new(%{name: name, prompt: "p", skills: ["a", "b"]})

    {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "p", skills: ["a", "b"]})
    :ok = RecipeRegistry.flush_cache()

    assert {:ok, role} = RecipeRegistry.lookup(ws, name)
    assert role == expected
  end

  test "read-through parity: requested_caps round-trip to ATOM values (== in-memory recipe)",
       %{name: name, system_ws: ws} do
    # A recipe with a behavior + a requested cap on it. The in-memory %Recipe{}
    # (what the old compiled lookup returned) carries atom-valued caps. The
    # seeded role MUST rehydrate to the SAME atom-valued shape (not JSON strings)
    # so a built-in and a user role instantiate identically (SPEC §10).
    recipe = %{
      name: name,
      behaviors: [Ezagent.ActionSet.Terminable],
      requested_caps: [%{behavior: Ezagent.ActionSet.Terminable, action: :terminate}]
    }

    {:ok, in_memory} = Ezagent.Agent.Recipe.new(recipe)

    {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(recipe)
    :ok = RecipeRegistry.flush_cache()

    assert {:ok, rehydrated} = RecipeRegistry.lookup(ws, name)
    # Byte-identical to the in-memory recipe — caps carry MODULE + ATOM values.
    assert rehydrated == in_memory

    assert [%{behavior: Ezagent.ActionSet.Terminable, action: :terminate}] =
             rehydrated.requested_caps
  end

  test "behaviors round-trip through ConfigStore (atom → string → loaded module)",
       %{name: name, system_ws: ws} do
    {:ok, :seeded} =
      RecipeRegistry.seed_role_if_absent(%{name: name, behaviors: [Ezagent.ActionSet.Terminable]})

    # Stored as a module-name STRING (JSON-safe).
    assert {:ok, %ConfigObject{body: %{"behaviors" => ["Elixir.Ezagent.ActionSet.Terminable"]}}} =
             resolve_role_object(ws, name)

    :ok = RecipeRegistry.flush_cache()
    # Rehydrated back to the loaded module atom by Recipe.new/1.
    assert {:ok, %Ezagent.Agent.Recipe{behaviors: [Ezagent.ActionSet.Terminable]}} =
             RecipeRegistry.lookup(ws, name)
  end

  # ---- §8.1 back-compat single-arg lookup resolves the system workspace ------

  test "lookup/1 (back-compat) resolves the built-in from the system workspace",
       %{name: name} do
    {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "p"})
    :ok = RecipeRegistry.flush_cache()
    assert {:ok, %Ezagent.Agent.Recipe{name: ^name}} = RecipeRegistry.lookup(name)
  end

  test "lookup returns :error for an unseeded role", %{name: name, system_ws: ws} do
    assert :error = RecipeRegistry.lookup(ws, "never-seeded-#{name}")
  end

  # ---- §8.4 seed idempotency (re-seed is a no-op, no second object) ----------

  test "re-seeding the same recipe is idempotent — no second object, pointer unmoved",
       %{name: name, system_ws: ws} do
    recipe = %{name: name, prompt: "p"}
    assert {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(recipe)
    {:ok, %ConfigObject{id: first_id}} = resolve_role_object(ws, name)

    # Re-seed: pointer already exists → no-op.
    assert {:ok, :exists} = RecipeRegistry.seed_role_if_absent(recipe)

    {:ok, %ConfigObject{id: second_id}} = resolve_role_object(ws, name)
    assert first_id == second_id

    # Exactly ONE object row for this role subject.
    assert 1 == count_objects(role_subject(ws, name))
  end

  test "re-seeding a recipe WITH atom-valued requested_caps is idempotent (cold-restart)",
       %{name: name, system_ws: ws} do
    # Regression for the role-seed cold-restart collision: a recipe carrying
    # `requested_caps` (atom MODULE + atom action VALUES, e.g. the orchestrator
    # role) JSON-serializes those values to strings on WRITE, but the re-seed's
    # comparison only stringified KEYS — so `pointed.body != seed_body` and a
    # plain BEAM reboot against a seeded DB raised `{:role_seed_collision, _}`,
    # breaking boot of every plugin that declares such a role (cc/orchestrator).
    # The existing idempotency test above uses a capless recipe, so it never
    # exercised this path. Asserts the 2nd seed is a no-op, NOT a collision.
    recipe = %{
      name: name,
      prompt: "p",
      behaviors: [Ezagent.ActionSet.Template],
      requested_caps: [
        %{behavior: Ezagent.ActionSet.Template, action: :read},
        %{behavior: Ezagent.ActionSet.Template, action: :write}
      ]
    }

    assert {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(recipe)
    {:ok, %ConfigObject{id: first_id}} = resolve_role_object(ws, name)

    # The reboot path: identical recipe, same deterministic seed source_turn_id.
    # Pre-fix this returned {:error, {:role_seed_collision, name}}.
    assert {:ok, :exists} = RecipeRegistry.seed_role_if_absent(recipe)

    {:ok, %ConfigObject{id: second_id}} = resolve_role_object(ws, name)
    assert first_id == second_id
    assert 1 == count_objects(role_subject(ws, name))
  end

  # ---- §8.5 seed override-safety (a published edit survives a re-seed) -------

  test "re-seed does NOT clobber a published override of the built-in",
       %{name: name, system_ws: ws} do
    {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "original"})

    # Simulate a tenant publishing an OVERRIDE of the built-in (re-point the
    # role's workspace-layer pointer to a new object body) — the CR publish path
    # in production; here driven directly via write_and_point.
    {:ok, _} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: ws,
        subject_uri: role_subject(ws, name),
        key: "recipe",
        body: %{"name" => name, "prompt" => "overridden"},
        actor_uri: "entity://system/user/admin",
        source_turn_id: "override-#{System.unique_integer([:positive])}"
      })

    # Re-seed (a reboot) MUST NOT clobber the override.
    assert {:ok, :exists} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "original"})

    :ok = RecipeRegistry.flush_cache()
    assert {:ok, %Ezagent.Agent.Recipe{prompt: "overridden"}} = RecipeRegistry.lookup(ws, name)
  end

  # ---- §8.6 seed collision (two plugins, same name, different body) ----------

  test "two different bodies under the same role name fail loud at seed (SAME boot)",
       %{name: name} do
    assert {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "a"})

    # No boot reset between the two seeds → a genuine two-plugins-one-name
    # collision (NOT a cross-version upgrade), caught by the per-boot registry.
    assert {:error, {:role_seed_collision, ^name}} =
             RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "DIFFERENT"})
  end

  # ---- #1223 M2 reflow — cross-version SELF-UPGRADE (not a collision) ---------

  describe "cross-version self-upgrade (reflow-carried DB, #1223 M2)" do
    test "a NEW body over a PRIOR-boot seed (same deterministic turn) UPGRADES, not collides",
         %{name: name, system_ws: ws} do
      %ConfigObject{id: v1_id} = seed_prior_boot!(ws, name, "v1")

      # New-version boot: the plugin ships a DIFFERENT body. PRE-FIX this hit
      # `seed_branch` case 2 (body differs + same seed turn id) → collision.
      # POST-FIX it UPGRADES (writes a new object + repoints, append-only).
      assert {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "v2"})

      assert {:ok, %ConfigObject{id: v2_id, source_turn_id: turn}} =
               resolve_role_object(ws, name)

      assert v2_id != v1_id
      assert String.starts_with?(turn, "role-seed-upgrade:")

      :ok = RecipeRegistry.flush_cache()
      assert {:ok, %Ezagent.Agent.Recipe{prompt: "v2"}} = RecipeRegistry.lookup(ws, name)
    end

    test "the upgrade is idempotent under an entrypoint retry (crash → restart re-seeds)",
         %{name: name, system_ws: ws} do
      seed_prior_boot!(ws, name, "v1")

      assert {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "v2"})
      {:ok, %ConfigObject{id: upgraded_id}} = resolve_role_object(ws, name)

      # Crash-restart: a FRESH boot (registry cleared) re-runs the SAME seed. The
      # body already matches → no new object, pointer unmoved.
      :ok = RecipeRegistry.reset_boot_seed_registry()
      assert {:ok, :exists} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "v2"})

      {:ok, %ConfigObject{id: same_id}} = resolve_role_object(ws, name)
      assert same_id == upgraded_id
    end

    test "a torn upgrade write (upgrade object already present) resolves :already_upgraded",
         %{name: name, system_ws: ws} do
      seed_prior_boot!(ws, name, "v1")

      # v2 as seed_role_if_absent stores it — recipe_body always adds `behaviors`,
      # so pass it explicitly to make the persisted body (and thus the hash-carrying
      # upgrade turn id) deterministic.
      v2_body = %{"name" => name, "prompt" => "v2", "behaviors" => []}
      upgrade_turn = "role-seed-upgrade:#{ws}:#{name}:#{ContentHash.of(v2_body)}"

      # A PRIOR boot wrote the upgrade OBJECT but crashed before repointing (the
      # object exists, the pointer still aims at v1). Insert it directly (no
      # pointer) to reproduce the torn state.
      {:ok, _} =
        %{
          id: Ecto.UUID.generate(),
          workspace_uri: ws,
          subject_uri: RecipeRegistry.recipe_subject_uri(ws, name),
          key: "recipe",
          body: v2_body,
          content_hash: ContentHash.of(v2_body),
          created_by: "entity://system/user/admin",
          source_turn_id: upgrade_turn
        }
        |> ConfigObject.changeset()
        |> EzagentCore.Repo.insert()

      # The retry re-hits the unique (ws, subject, key, source_turn_id) index →
      # idempotent success (the entrypoint retry loop survives, same as #1235).
      assert {:ok, :already_upgraded} =
               RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "v2", behaviors: []})
    end
  end

  # ---- §8.3 cross-workspace fallback (tenant sees system built-in; forks) ----

  test "lookup in a tenant ws falls back to the system built-in, then prefers a tenant fork",
       %{name: name, system_ws: system_ws} do
    tenant_ws = Ezagent.URI.workspace("tenant-#{System.unique_integer([:positive])}") |> URI.to_string()

    {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "system"})
    :ok = RecipeRegistry.flush_cache()

    # No tenant role yet → fall back to the system built-in.
    assert {:ok, %Ezagent.Agent.Recipe{prompt: "system"}} = RecipeRegistry.lookup(tenant_ws, name)

    # Tenant FORKS: write its own role object at the tenant subject.
    {:ok, _} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: tenant_ws,
        subject_uri: role_subject(tenant_ws, name),
        key: "recipe",
        body: %{"name" => name, "prompt" => "tenant-fork"},
        actor_uri: "entity://system/user/admin",
        source_turn_id: "fork-#{System.unique_integer([:positive])}"
      })

    RecipeRegistry.invalidate(tenant_ws, name)
    # Now the tenant's own fork wins for that tenant; system built-in is unchanged.
    assert {:ok, %Ezagent.Agent.Recipe{prompt: "tenant-fork"}} = RecipeRegistry.lookup(tenant_ws, name)
    assert {:ok, %Ezagent.Agent.Recipe{prompt: "system"}} = RecipeRegistry.lookup(system_ws, name)
  end

  # ---- §5.3 / OQ-1=b scriptless data-role guard -----------------------------

  test "validate_data_role_recipe REJECTS a user-authored role carrying a script",
       %{name: name} do
    assert {:error, {:script_not_allowed_in_data_role, ^name}} =
             RecipeRegistry.validate_data_role_recipe(%{name: name, script: "import os"})
  end

  test "validate_data_role_recipe ACCEPTS a scriptless user-authored role", %{name: name} do
    assert {:ok, %Ezagent.Agent.Recipe{name: ^name, script: nil}} =
             RecipeRegistry.validate_data_role_recipe(%{name: name, prompt: "persona", skills: ["x"]})
  end

  test "validate_data_role_recipe still enforces the Recipe.new/1 invariants (flavor reject)",
       %{name: name} do
    assert {:error, {:invalid_role_recipe, ^name, {:flavor_field_in_role, :flavor}}} =
             RecipeRegistry.validate_data_role_recipe(%{name: name, flavor: "cc"})
  end

  test "a built-in / operator-seeded role MAY carry a script (the trusted code path)",
       %{name: name, system_ws: ws} do
    # The seed path uses the (script-allowing) validate_recipe, NOT the data-role
    # guard — built-ins ship script as trusted CODE.
    assert {:ok, :seeded} =
             RecipeRegistry.seed_role_if_absent(%{name: name, script: "print('np')"})

    :ok = RecipeRegistry.flush_cache()
    assert {:ok, %Ezagent.Agent.Recipe{script: "print('np')"}} = RecipeRegistry.lookup(ws, name)
  end

  # ---- cache invalidation ----------------------------------------------------

  test "invalidate drops the cached role so the next lookup re-resolves",
       %{name: name, system_ws: ws} do
    {:ok, :seeded} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "v1"})
    assert {:ok, %Ezagent.Agent.Recipe{prompt: "v1"}} = RecipeRegistry.lookup(ws, name)

    # Mutate the underlying config object (re-point), then invalidate.
    {:ok, _} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: ws,
        subject_uri: role_subject(ws, name),
        key: "recipe",
        body: %{"name" => name, "prompt" => "v2"},
        actor_uri: "entity://system/user/admin",
        source_turn_id: "repoint-#{System.unique_integer([:positive])}"
      })

    # Stale cache still returns v1 until invalidated.
    assert {:ok, %Ezagent.Agent.Recipe{prompt: "v1"}} = RecipeRegistry.lookup(ws, name)
    :ok = RecipeRegistry.invalidate(ws, name)
    assert {:ok, %Ezagent.Agent.Recipe{prompt: "v2"}} = RecipeRegistry.lookup(ws, name)
  end

  defp count_objects(subject_uri) do
    import Ecto.Query

    EzagentCore.Repo.one(
      from(o in ConfigObject, where: o.subject_uri == ^subject_uri, select: count(o.id))
    )
  end
end
