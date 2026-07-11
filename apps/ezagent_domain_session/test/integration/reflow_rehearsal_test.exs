defmodule Ezagent.Socialware.ReflowRehearsalTest do
  @moduledoc """
  CI reflow-rehearsal gate (the THIRD-state seed contract, #1235/#1240/#1223 M2).

  Three deploys failed because boot seeds only handled TWO states (absent → write,
  same → skip); the THIRD — the DB already holds an OLDER version of this exact
  seed, which EVERY reflow-carrying deploy produces — crashed. This test simulates
  what a reflowed DB holds (definitions + recipes written with SIMULATED OLD bodies
  under their SEED-FAMILY `source_turn_id`s, directly via `ConfigStore`) and then
  runs the REAL boot seed paths against it — asserting zero raises.

  ## Definition lane — DEFAULT NO-CLOBBER (Allen 2026-07-10)

  The DEFINITION boot seed no longer auto-upgrades a reflow-carried older
  definition (that would clobber an intentional runtime change). It now leaves the
  divergent stored definition AS-IS and surfaces the conflict; the current
  built-in is applied only on an EXPLICIT `reseed_builtin_definition/1` force.
  This test asserts both: boot does not raise and does not clobber, then a force
  upgrades. (The RECIPE lane below is unchanged — `seed_role_if_absent/1` still
  upgrades a reflow-carried older recipe; the no-clobber ruling was scoped to app
  definitions.)

  This is deterministic (no docker, no external services) and belongs in the
  ubuntu gate. The FULL-FIDELITY rehearsal — provision a PREVIOUS release's DB,
  boot the current release's OTP app end-to-end — remains the deploy pipeline's
  job; this catches the third-state seed regression class cheaply and honestly.
  """
  use EzagentCore.DataCase, async: false

  @moduletag :reflow_rehearsal

  alias Ezagent.Agent.RecipeRegistry

  alias Ezagent.Socialware.{
    ConfigObject,
    ConfigPointer,
    ConfigStore,
    ContentHash,
    Definition,
    DefinitionRegistry
  }

  # ---- Definition boot seed against a reflow-carried OLDER definition --------

  test "seed_builtin_definitions does NOT clobber a reflow-carried OLD built-in (no raise); force upgrades" do
    ws = DefinitionRegistry.system_workspace_uri()
    subject = DefinitionRegistry.definition_subject_uri(ws, "socialware")

    # Clean-slate the socialware definition subject IN the sandbox (rolled back at
    # test end) so the simulated reflow row is deterministic regardless of any
    # socialware seed a dev's shared DB already committed. CI's fresh DB has none;
    # this makes local + CI behave identically. No FK on config_id, so order is free.
    import Ecto.Query
    EzagentCore.Repo.delete_all(from(p in ConfigPointer, where: p.subject_uri == ^subject))
    EzagentCore.Repo.delete_all(from(o in ConfigObject, where: o.subject_uri == ^subject))

    # The current built-in `socialware` definition — its NEW body/hash.
    builtin = Enum.find(DefinitionRegistry.builtin_definitions(), &(&1.name == "socialware"))
    new_hash = Definition.content_hash(Definition.body(builtin))

    # A reflowed DB holds an OLDER `socialware` body under the DETERMINISTIC
    # seed-family turn id (what a prior deploy's boot seed wrote).
    old_body = builtin |> Definition.body() |> Map.put("prompt", "OLD reflow-carried body")
    refute Definition.content_hash(old_body) == new_hash

    {:ok, %{object: %ConfigObject{id: old_id}}} =
      ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: ws,
        subject_uri: subject,
        key: DefinitionRegistry.definition_key(),
        body: old_body,
        actor_uri: "entity://system/user/admin",
        source_turn_id: "socialware-definition-seed:#{ws}:socialware"
      })

    # The REAL boot seed path — must NOT raise, and (default no-clobber) must NOT
    # overwrite the reflow-carried divergent definition.
    assert :ok = DefinitionRegistry.seed_builtin_definitions()

    assert {:ok, %ConfigObject{id: ^old_id}} =
             ConfigStore.resolve("workspace", ws, subject, DefinitionRegistry.definition_key())

    assert Enum.any?(
             DefinitionRegistry.builtin_definition_divergences(),
             &(&1.name == "socialware")
           )

    # An EXPLICIT force applies the current built-in (content-safe upgrade).
    assert {:ok, :seeded} = DefinitionRegistry.reseed_builtin_definition("socialware")

    assert {:ok, %ConfigObject{id: upgraded_id, content_hash: ^new_hash, source_turn_id: turn}} =
             ConfigStore.resolve("workspace", ws, subject, DefinitionRegistry.definition_key())

    assert upgraded_id != old_id
    assert String.starts_with?(turn, "socialware-definition-seed-upgrade:")

    # Idempotent — a second force over the now-current DB is a no-op (no raise).
    assert {:ok, :exists} = DefinitionRegistry.reseed_builtin_definition("socialware")
  end

  # ---- Role/recipe boot seed against a reflow-carried OLDER recipe -----------

  test "seed_role_if_absent UPGRADES a reflow-carried OLD recipe without raising" do
    ws = RecipeRegistry.system_workspace_uri()
    name = "reflow-role-#{System.unique_integer([:positive])}"
    subject = RecipeRegistry.recipe_subject_uri(ws, name)

    # A reflowed DB holds an OLD recipe body under the deterministic seed turn id
    # (a PRIOR boot; the per-boot registry is empty for this name — exactly a
    # cross-version reboot, not a same-boot two-plugins collision).
    {:ok, %{object: %ConfigObject{id: old_id}}} =
      ConfigStore.write_and_point(%{
        layer: RecipeRegistry.recipe_layer(),
        workspace_uri: ws,
        subject_uri: subject,
        key: RecipeRegistry.recipe_key(),
        body: %{"name" => name, "prompt" => "old", "behaviors" => []},
        actor_uri: "entity://system/user/admin",
        source_turn_id: "role-seed:#{ws}:#{name}"
      })

    # The REAL boot seed path (what `Ezagent.Plugin.boot/1` runs per roles/0 recipe).
    assert {:ok, :seeded} =
             RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "new"})

    assert {:ok, %ConfigObject{id: upgraded_id, source_turn_id: turn, body: %{"prompt" => "new"}}} =
             ConfigStore.resolve(
               RecipeRegistry.recipe_layer(),
               ws,
               subject,
               RecipeRegistry.recipe_key()
             )

    assert upgraded_id != old_id
    assert String.starts_with?(turn, "role-seed-upgrade:")

    assert new_hash_matches?(
             subject,
             ContentHash.of(%{"name" => name, "prompt" => "new", "behaviors" => []})
           )

    # A crash-restart re-seed (fresh per-boot registry) is idempotent — no raise.
    :ok = RecipeRegistry.reset_boot_seed_registry()
    assert {:ok, :exists} = RecipeRegistry.seed_role_if_absent(%{name: name, prompt: "new"})
  end

  defp new_hash_matches?(subject, expected) do
    import Ecto.Query

    EzagentCore.Repo.one(
      from(o in ConfigObject,
        where: o.subject_uri == ^subject and o.content_hash == ^expected,
        select: count(o.id)
      )
    ) >= 1
  end
end
