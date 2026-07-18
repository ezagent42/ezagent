defmodule Ezagent.Socialware.DefinitionRegistryReseedTest do
  @moduledoc """
  End-to-end coverage for the re-seed / migrate-stale-app-definition capability
  under the DEFAULT NO-CLOBBER policy (Allen 2026-07-10), driven through the
  ORCHESTRATOR built-in — the concrete definition #1332 left stale.

  Contract points:

    * BOOT (`seed_builtin_definitions/0`) NEVER overwrites a stored definition
      that DIVERGES from code — it surfaces the conflict (log + telemetry) and
      leaves the stored object as-is;
    * BOOT seeds an ABSENT definition (create-if-absent) and no-ops a stored
      definition that already matches code;
    * FORCE (`reseed_builtin_definition/1`) applies the code version to a
      divergent stored definition, content-safe (a NEW immutable object +
      repoint, never a raw UPDATE);
    * FORCE never touches a tenant-workspace override (workspace separation).

  The versioned upsert primitive itself is unit-tested in
  `Ezagent.Socialware.ConfigStoreSeedUpsertTest`.
  """
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Socialware.{
    ConfigObject,
    ConfigPointer,
    ConfigStore,
    Definition,
    DefinitionRegistry
  }

  @orchestrator "orchestrator"
  @team_a "workspace://team-a"

  defp system_ws, do: DefinitionRegistry.system_workspace_uri()

  defp subject, do: DefinitionRegistry.definition_subject_uri(system_ws(), @orchestrator)

  setup do
    # The boot seed COMMITS the built-in definitions to the real test DB at
    # application start, so every DataCase test sees them. Clear the orchestrator
    # subject INSIDE this test's sandbox transaction (rolled back at test end) so
    # each test starts from a known state — pointers first, then the objects.
    Repo.delete_all(from(p in ConfigPointer, where: p.subject_uri == ^subject()))
    Repo.delete_all(from(o in ConfigObject, where: o.subject_uri == ^subject()))
    :ok
  end

  defp orchestrator_body(flavor, provider \\ nil) do
    role = %{role_name: @orchestrator, fill: :agent, recipe: @orchestrator, flavor: flavor}
    role = if provider, do: Map.put(role, :provider, provider), else: role

    {:ok, definition} =
      Definition.new(%{
        name: @orchestrator,
        version: "0.1.0",
        title: "Orchestrator",
        description: "Stock cc orchestrator team front desk.",
        uses: ["cc"],
        roles: [role],
        views: [],
        routing_rules: [],
        visibility_policy: %{publish_policy: :auto, web_anon_access: false}
      })

    Definition.body(definition)
  end

  # Seed a PRIOR system-ws orchestrator definition at an arbitrary `flavor`
  # (+ optional cc-custom `provider`), as if an older build had seeded it.
  # Uses the content-safe append-and-repoint write directly so the test
  # controls the starting state.
  defp seed_prior_system_orchestrator!(flavor, provider \\ nil) do
    {:ok, %{object: object}} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: system_ws(),
        subject_uri: subject(),
        key: DefinitionRegistry.definition_key(),
        body: orchestrator_body(flavor, provider),
        actor_uri: "entity://system/user/admin",
        source_turn_id: "legacy-orchestrator-seed:#{System.unique_integer([:positive])}"
      })

    object
  end

  # Count immutable objects for the SYSTEM-ws orchestrator subject only (the
  # subject string is workspace-independent, so scope by workspace_uri).
  defp system_object_count do
    Repo.one(
      from(o in ConfigObject,
        where: o.workspace_uri == ^system_ws() and o.subject_uri == ^subject(),
        select: count(o.id)
      )
    )
  end

  defp flavor_of(%Definition{roles: [role | _]}), do: role.flavor
  defp provider_of(%Definition{roles: [role | _]}), do: Map.get(role, :provider)

  defp orchestrator_divergence do
    DefinitionRegistry.builtin_definition_divergences()
    |> Enum.find(&(&1.name == @orchestrator))
  end

  # ---- BOOT: default no-clobber on divergence --------------------------------

  test "boot no-clobber — a divergent stored `cc` definition is NOT overwritten" do
    old = seed_prior_system_orchestrator!("cc")

    assert :ok = DefinitionRegistry.seed_builtin_definitions()

    # stored definition is untouched — still cc, same object, no new object
    {:ok, definition, object} = DefinitionRegistry.lookup(system_ws(), @orchestrator)
    assert flavor_of(definition) == "cc"
    assert object.id == old.id
    assert 1 == system_object_count()
  end

  test "boot no-clobber — the divergence is surfaced (report + telemetry)" do
    seed_prior_system_orchestrator!("cc")

    handler = {__MODULE__, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler,
      [:ezagent, :socialware, :definition, :divergence],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:divergence_telemetry, event, measurements, metadata})
      end,
      nil
    )

    try do
      assert :ok = DefinitionRegistry.seed_builtin_definitions()

      assert_receive {:divergence_telemetry, [:ezagent, :socialware, :definition, :divergence],
                      %{count: 1}, %{name: @orchestrator, stored_hash: stored, code_hash: code}}

      assert is_binary(stored) and is_binary(code) and stored != code
    after
      :telemetry.detach(handler)
    end

    # the read-only report agrees
    assert %{name: @orchestrator, stored_hash: _, code_hash: _} = orchestrator_divergence()
  end

  # ---- BOOT: absent seeds, current no-ops ------------------------------------

  test "boot seed — an ABSENT definition is seeded from the code (create-if-absent)" do
    assert 0 == system_object_count()

    assert :ok = DefinitionRegistry.seed_builtin_definitions()

    {:ok, definition, _} = DefinitionRegistry.lookup(system_ws(), @orchestrator)
    assert flavor_of(definition) == "cc-custom"
    assert provider_of(definition) == "deepseek"
    assert is_nil(orchestrator_divergence())
  end

  test "boot seed — a stored definition already matching code is a no-op (no new object)" do
    seed_prior_system_orchestrator!("cc-custom", "deepseek")
    assert 1 == system_object_count()

    assert :ok = DefinitionRegistry.seed_builtin_definitions()

    assert 1 == system_object_count()
    assert is_nil(orchestrator_divergence())
  end

  # ---- FORCE: apply the code version, content-safe ---------------------------

  test "force — applies the code version to a divergent stored def (new object + repoint)" do
    old = seed_prior_system_orchestrator!("cc")

    assert {:ok, :seeded} = DefinitionRegistry.reseed_builtin_definition(@orchestrator)

    {:ok, definition, object} = DefinitionRegistry.lookup(system_ws(), @orchestrator)

    # migrated to the code flavor
    assert flavor_of(definition) == "cc-custom"
    assert provider_of(definition) == "deepseek"
    # content-safe: a NEW immutable object at a NEW hash, old one retained
    assert object.id != old.id
    assert object.content_hash != old.content_hash
    assert 2 == system_object_count()
    assert %ConfigObject{} = ConfigStore.get!(old.id)
  end

  test "force — a tenant-workspace override is NOT affected" do
    seed_prior_system_orchestrator!("cc")

    {:ok, tenant_object} =
      DefinitionRegistry.write_definition(
        %{
          name: @orchestrator,
          uses: ["cc"],
          roles: [
            %{
              role_name: @orchestrator,
              fill: :agent,
              recipe: @orchestrator,
              flavor: "tenant-custom"
            }
          ],
          visibility_policy: %{scope: :private}
        },
        workspace_uri: @team_a,
        caller_workspace_uri: @team_a,
        actor_uri: "entity://team-a/user/alice"
      )

    assert {:ok, :seeded} = DefinitionRegistry.reseed_builtin_definition(@orchestrator)

    {:ok, system_definition, _} = DefinitionRegistry.lookup(system_ws(), @orchestrator)
    assert flavor_of(system_definition) == "cc-custom"

    {:ok, tenant_definition, tenant_object_after} =
      DefinitionRegistry.lookup(@team_a, @orchestrator)

    assert flavor_of(tenant_definition) == "tenant-custom"
    assert tenant_object_after.id == tenant_object.id
  end

  test "force — re-applying an already-current definition mints no new object" do
    seed_prior_system_orchestrator!("cc")

    assert {:ok, :seeded} = DefinitionRegistry.reseed_builtin_definition(@orchestrator)
    assert 2 == system_object_count()

    assert {:ok, :exists} = DefinitionRegistry.reseed_builtin_definition(@orchestrator)
    assert 2 == system_object_count()
  end

  test "force — an unknown built-in name fails loud" do
    assert {:error, {:unknown_builtin_definition, "does-not-exist"}} =
             DefinitionRegistry.reseed_builtin_definition("does-not-exist")
  end

  # ---- source-of-truth parity ------------------------------------------------

  test "the orchestrator built-in seed body declares the cc-custom flavor + deepseek provider" do
    orchestrator =
      DefinitionRegistry.builtin_definitions()
      |> Enum.find(&(&1.name == @orchestrator))

    assert flavor_of(orchestrator) == "cc-custom"
    assert provider_of(orchestrator) == "deepseek"
  end
end
