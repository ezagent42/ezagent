defmodule Ezagent.Agent.RoleRegistryTest do
  @moduledoc """
  role-as-data (SPEC §3/§4/§5.3) — `Ezagent.Agent.RoleRegistry` read-through over
  `Ezagent.Socialware.ConfigStore`, idempotent + override-safe seeding, the
  cross-workspace fallback, and the scriptless data-role guard (OQ-1=b).

  These are the SPEC §8 deltas: role-is-its-own-subject, lookup read-through
  parity (ETS = cache, ConfigStore = authority), seed idempotency/override-
  safety/collision, and the script authoring gate.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RoleRegistry
  alias Ezagent.Socialware.{ConfigObject, ConfigStore}

  setup do
    # Each test uses a UNIQUE role name so the shared ETS cache + the appended
    # ConfigObject rows never collide across tests.
    name = "role-test-#{System.unique_integer([:positive])}"
    RoleRegistry.invalidate(RoleRegistry.system_workspace_uri(), name)
    %{name: name, system_ws: RoleRegistry.system_workspace_uri()}
  end

  defp role_subject(ws, name), do: RoleRegistry.role_subject_uri(ws, name)

  defp resolve_role_object(ws, name) do
    ConfigStore.resolve("workspace", ws, role_subject(ws, name), RoleRegistry.role_key())
  end

  # ---- §8.1 role is its OWN subject; seed writes CONFIG (not just ETS) -------

  test "seed_role_if_absent writes a role ConfigObject resolvable at config://<sys>/role/<name>",
       %{name: name, system_ws: ws} do
    assert {:ok, :seeded} =
             RoleRegistry.seed_role_if_absent(%{name: name, prompt: "hello", skills: ["s1"]})

    # The seed wrote a real ConfigObject (proves config, not ETS).
    assert {:ok, %ConfigObject{body: body, subject_uri: subj, key: "role"}} =
             resolve_role_object(ws, name)

    assert subj == role_subject(ws, name)
    assert body["name"] == name
    assert body["prompt"] == "hello"
    assert body["skills"] == ["s1"]
  end

  # ---- §8.2 lookup read-through (ETS flushed → resolves from ConfigStore) ----

  test "lookup resolves read-through from ConfigStore after the ETS cache is flushed",
       %{name: name, system_ws: ws} do
    {:ok, :seeded} = RoleRegistry.seed_role_if_absent(%{name: name, prompt: "p"})

    # Flush the ENTIRE cache — proves the next lookup resolves from ConfigStore,
    # not a surviving ETS write (the elimination invariant, §7.2).
    :ok = RoleRegistry.flush_cache()

    assert {:ok, %Ezagent.Role{name: ^name, prompt: "p"}} = RoleRegistry.lookup(ws, name)
  end

  test "lookup parity: read-through role == the seeded recipe (rehydrated via Role.new/1)",
       %{name: name, system_ws: ws} do
    {:ok, expected} = Ezagent.Role.new(%{name: name, prompt: "p", skills: ["a", "b"]})

    {:ok, :seeded} = RoleRegistry.seed_role_if_absent(%{name: name, prompt: "p", skills: ["a", "b"]})
    :ok = RoleRegistry.flush_cache()

    assert {:ok, role} = RoleRegistry.lookup(ws, name)
    assert role == expected
  end

  test "read-through parity: requested_caps round-trip to ATOM values (== in-memory recipe)",
       %{name: name, system_ws: ws} do
    # A recipe with a behavior + a requested cap on it. The in-memory %Role{}
    # (what the old compiled lookup returned) carries atom-valued caps. The
    # seeded role MUST rehydrate to the SAME atom-valued shape (not JSON strings)
    # so a built-in and a user role instantiate identically (SPEC §10).
    recipe = %{
      name: name,
      behaviors: [Ezagent.Behavior.Terminable],
      requested_caps: [%{behavior: Ezagent.Behavior.Terminable, action: :terminate}]
    }

    {:ok, in_memory} = Ezagent.Role.new(recipe)

    {:ok, :seeded} = RoleRegistry.seed_role_if_absent(recipe)
    :ok = RoleRegistry.flush_cache()

    assert {:ok, rehydrated} = RoleRegistry.lookup(ws, name)
    # Byte-identical to the in-memory recipe — caps carry MODULE + ATOM values.
    assert rehydrated == in_memory

    assert [%{behavior: Ezagent.Behavior.Terminable, action: :terminate}] =
             rehydrated.requested_caps
  end

  test "behaviors round-trip through ConfigStore (atom → string → loaded module)",
       %{name: name, system_ws: ws} do
    {:ok, :seeded} =
      RoleRegistry.seed_role_if_absent(%{name: name, behaviors: [Ezagent.Behavior.Terminable]})

    # Stored as a module-name STRING (JSON-safe).
    assert {:ok, %ConfigObject{body: %{"behaviors" => ["Elixir.Ezagent.Behavior.Terminable"]}}} =
             resolve_role_object(ws, name)

    :ok = RoleRegistry.flush_cache()
    # Rehydrated back to the loaded module atom by Role.new/1.
    assert {:ok, %Ezagent.Role{behaviors: [Ezagent.Behavior.Terminable]}} =
             RoleRegistry.lookup(ws, name)
  end

  # ---- §8.1 back-compat single-arg lookup resolves the system workspace ------

  test "lookup/1 (back-compat) resolves the built-in from the system workspace",
       %{name: name} do
    {:ok, :seeded} = RoleRegistry.seed_role_if_absent(%{name: name, prompt: "p"})
    :ok = RoleRegistry.flush_cache()
    assert {:ok, %Ezagent.Role{name: ^name}} = RoleRegistry.lookup(name)
  end

  test "lookup returns :error for an unseeded role", %{name: name, system_ws: ws} do
    assert :error = RoleRegistry.lookup(ws, "never-seeded-#{name}")
  end

  # ---- §8.4 seed idempotency (re-seed is a no-op, no second object) ----------

  test "re-seeding the same recipe is idempotent — no second object, pointer unmoved",
       %{name: name, system_ws: ws} do
    recipe = %{name: name, prompt: "p"}
    assert {:ok, :seeded} = RoleRegistry.seed_role_if_absent(recipe)
    {:ok, %ConfigObject{id: first_id}} = resolve_role_object(ws, name)

    # Re-seed: pointer already exists → no-op.
    assert {:ok, :exists} = RoleRegistry.seed_role_if_absent(recipe)

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
      behaviors: [Ezagent.Behavior.Template],
      requested_caps: [
        %{behavior: Ezagent.Behavior.Template, action: :read},
        %{behavior: Ezagent.Behavior.Template, action: :write}
      ]
    }

    assert {:ok, :seeded} = RoleRegistry.seed_role_if_absent(recipe)
    {:ok, %ConfigObject{id: first_id}} = resolve_role_object(ws, name)

    # The reboot path: identical recipe, same deterministic seed source_turn_id.
    # Pre-fix this returned {:error, {:role_seed_collision, name}}.
    assert {:ok, :exists} = RoleRegistry.seed_role_if_absent(recipe)

    {:ok, %ConfigObject{id: second_id}} = resolve_role_object(ws, name)
    assert first_id == second_id
    assert 1 == count_objects(role_subject(ws, name))
  end

  # ---- §8.5 seed override-safety (a published edit survives a re-seed) -------

  test "re-seed does NOT clobber a published override of the built-in",
       %{name: name, system_ws: ws} do
    {:ok, :seeded} = RoleRegistry.seed_role_if_absent(%{name: name, prompt: "original"})

    # Simulate a tenant publishing an OVERRIDE of the built-in (re-point the
    # role's workspace-layer pointer to a new object body) — the CR publish path
    # in production; here driven directly via write_and_point.
    {:ok, _} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: ws,
        subject_uri: role_subject(ws, name),
        key: "role",
        body: %{"name" => name, "prompt" => "overridden"},
        actor_uri: "entity://system/user/admin",
        source_turn_id: "override-#{System.unique_integer([:positive])}"
      })

    # Re-seed (a reboot) MUST NOT clobber the override.
    assert {:ok, :exists} = RoleRegistry.seed_role_if_absent(%{name: name, prompt: "original"})

    :ok = RoleRegistry.flush_cache()
    assert {:ok, %Ezagent.Role{prompt: "overridden"}} = RoleRegistry.lookup(ws, name)
  end

  # ---- §8.6 seed collision (two plugins, same name, different body) ----------

  test "two different bodies under the same role name fail loud at seed",
       %{name: name} do
    assert {:ok, :seeded} = RoleRegistry.seed_role_if_absent(%{name: name, prompt: "a"})

    assert {:error, {:role_seed_collision, ^name}} =
             RoleRegistry.seed_role_if_absent(%{name: name, prompt: "DIFFERENT"})
  end

  # ---- §8.3 cross-workspace fallback (tenant sees system built-in; forks) ----

  test "lookup in a tenant ws falls back to the system built-in, then prefers a tenant fork",
       %{name: name, system_ws: system_ws} do
    tenant_ws = Ezagent.URI.workspace("tenant-#{System.unique_integer([:positive])}") |> URI.to_string()

    {:ok, :seeded} = RoleRegistry.seed_role_if_absent(%{name: name, prompt: "system"})
    :ok = RoleRegistry.flush_cache()

    # No tenant role yet → fall back to the system built-in.
    assert {:ok, %Ezagent.Role{prompt: "system"}} = RoleRegistry.lookup(tenant_ws, name)

    # Tenant FORKS: write its own role object at the tenant subject.
    {:ok, _} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: tenant_ws,
        subject_uri: role_subject(tenant_ws, name),
        key: "role",
        body: %{"name" => name, "prompt" => "tenant-fork"},
        actor_uri: "entity://system/user/admin",
        source_turn_id: "fork-#{System.unique_integer([:positive])}"
      })

    RoleRegistry.invalidate(tenant_ws, name)
    # Now the tenant's own fork wins for that tenant; system built-in is unchanged.
    assert {:ok, %Ezagent.Role{prompt: "tenant-fork"}} = RoleRegistry.lookup(tenant_ws, name)
    assert {:ok, %Ezagent.Role{prompt: "system"}} = RoleRegistry.lookup(system_ws, name)
  end

  # ---- §5.3 / OQ-1=b scriptless data-role guard -----------------------------

  test "validate_data_role_recipe REJECTS a user-authored role carrying a script",
       %{name: name} do
    assert {:error, {:script_not_allowed_in_data_role, ^name}} =
             RoleRegistry.validate_data_role_recipe(%{name: name, script: "import os"})
  end

  test "validate_data_role_recipe ACCEPTS a scriptless user-authored role", %{name: name} do
    assert {:ok, %Ezagent.Role{name: ^name, script: nil}} =
             RoleRegistry.validate_data_role_recipe(%{name: name, prompt: "persona", skills: ["x"]})
  end

  test "validate_data_role_recipe still enforces the Role.new/1 invariants (flavor reject)",
       %{name: name} do
    assert {:error, {:invalid_role_recipe, ^name, {:flavor_field_in_role, :flavor}}} =
             RoleRegistry.validate_data_role_recipe(%{name: name, flavor: "cc"})
  end

  test "a built-in / operator-seeded role MAY carry a script (the trusted code path)",
       %{name: name, system_ws: ws} do
    # The seed path uses the (script-allowing) validate_recipe, NOT the data-role
    # guard — built-ins ship script as trusted CODE.
    assert {:ok, :seeded} =
             RoleRegistry.seed_role_if_absent(%{name: name, script: "print('np')"})

    :ok = RoleRegistry.flush_cache()
    assert {:ok, %Ezagent.Role{script: "print('np')"}} = RoleRegistry.lookup(ws, name)
  end

  # ---- cache invalidation ----------------------------------------------------

  test "invalidate drops the cached role so the next lookup re-resolves",
       %{name: name, system_ws: ws} do
    {:ok, :seeded} = RoleRegistry.seed_role_if_absent(%{name: name, prompt: "v1"})
    assert {:ok, %Ezagent.Role{prompt: "v1"}} = RoleRegistry.lookup(ws, name)

    # Mutate the underlying config object (re-point), then invalidate.
    {:ok, _} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: ws,
        subject_uri: role_subject(ws, name),
        key: "role",
        body: %{"name" => name, "prompt" => "v2"},
        actor_uri: "entity://system/user/admin",
        source_turn_id: "repoint-#{System.unique_integer([:positive])}"
      })

    # Stale cache still returns v1 until invalidated.
    assert {:ok, %Ezagent.Role{prompt: "v1"}} = RoleRegistry.lookup(ws, name)
    :ok = RoleRegistry.invalidate(ws, name)
    assert {:ok, %Ezagent.Role{prompt: "v2"}} = RoleRegistry.lookup(ws, name)
  end

  defp count_objects(subject_uri) do
    import Ecto.Query

    EzagentCore.Repo.one(
      from(o in ConfigObject, where: o.subject_uri == ^subject_uri, select: count(o.id))
    )
  end
end
