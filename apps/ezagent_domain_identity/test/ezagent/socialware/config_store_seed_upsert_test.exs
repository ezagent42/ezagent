defmodule Ezagent.Socialware.ConfigStoreSeedUpsertTest do
  @moduledoc """
  The three-state seed contract of `Ezagent.Socialware.ConfigStore.seed_object_upsert/1`
  (the primitive that #1235 / #1240 hand-rolled independently in
  `DefinitionRegistry.seed_builtin_definition/2` and
  `RecipeRegistry.seed_role_if_absent/2`).

  One test per branch of the four-branch contract, plus the two provenance modes
  (`:seed_family_prefix` present = override-safe; absent = §5.2 always-upgrade),
  retry idempotency, and override survival. The SAME-BOOT two-plugins-one-name
  collision is deliberately NOT here — it is caller-side (see
  `Ezagent.Agent.RecipeRegistryTest` "two different bodies … fail loud (SAME boot)").
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{ConfigObject, ConfigStore, ContentHash}

  @layer "workspace"
  @key "recipe"

  setup do
    ws = Ezagent.URI.workspace("upsert-#{System.unique_integer([:positive])}") |> URI.to_string()
    name = "obj-#{System.unique_integer([:positive])}"
    subject = "recipe:#{name}"
    %{ws: ws, name: name, subject: subject}
  end

  defp attrs(ctx, body, overrides) do
    Map.merge(
      %{
        layer: @layer,
        workspace_uri: ctx.ws,
        subject_uri: ctx.subject,
        key: @key,
        body: body,
        actor_uri: "entity://system/user/admin",
        source_turn_id: "role-seed:#{ctx.ws}:#{ctx.name}",
        upgrade_source_turn_id: "role-seed-upgrade:#{ctx.ws}:#{ctx.name}:#{ContentHash.of(body)}",
        collision_tag: {:seed_collision, ctx.name}
      },
      Map.new(overrides)
    )
  end

  defp resolve(ctx),
    do: ConfigStore.resolve(@layer, ctx.ws, ctx.subject, @key)

  defp seed_prior!(ctx, body, turn) do
    {:ok, %{object: object}} =
      ConfigStore.write_and_point(%{
        layer: @layer,
        workspace_uri: ctx.ws,
        subject_uri: ctx.subject,
        key: @key,
        body: body,
        actor_uri: "entity://system/user/admin",
        source_turn_id: turn
      })

    object
  end

  defp count(ctx) do
    import Ecto.Query

    EzagentCore.Repo.one(
      from(o in ConfigObject, where: o.subject_uri == ^ctx.subject, select: count(o.id))
    )
  end

  # ---- Branch 1: no pointer → seed-once --------------------------------------

  test "branch 1 — no pointer → {:ok, :seeded}", ctx do
    assert {:ok, :seeded} = ConfigStore.seed_object_upsert(attrs(ctx, %{"v" => "1"}, %{}))
    assert {:ok, %ConfigObject{body: %{"v" => "1"}}} = resolve(ctx)
    assert 1 == count(ctx)
  end

  # ---- Branch 2: same body → no-op -------------------------------------------

  test "branch 2 — pointer exists, SAME body → {:ok, :exists} (no second object)", ctx do
    body = %{"v" => "1"}
    assert {:ok, :seeded} = ConfigStore.seed_object_upsert(attrs(ctx, body, %{}))
    {:ok, %ConfigObject{id: first}} = resolve(ctx)

    assert {:ok, :exists} = ConfigStore.seed_object_upsert(attrs(ctx, body, %{}))
    {:ok, %ConfigObject{id: second}} = resolve(ctx)

    assert first == second
    assert 1 == count(ctx)
  end

  # ---- Branch 3: seed-family divergence → upgrade ----------------------------

  test "branch 3 — body differs + seed-family turn (prefix present) → UPGRADE", ctx do
    %ConfigObject{id: v1} = seed_prior!(ctx, %{"v" => "1"}, "role-seed:#{ctx.ws}:#{ctx.name}")

    assert {:ok, :seeded} =
             ConfigStore.seed_object_upsert(
               attrs(ctx, %{"v" => "2"}, %{seed_family_prefix: "role-seed"})
             )

    assert {:ok, %ConfigObject{id: v2, body: %{"v" => "2"}, source_turn_id: turn}} = resolve(ctx)
    assert v2 != v1
    assert String.starts_with?(turn, "role-seed-upgrade:")
    assert 2 == count(ctx)
  end

  test "branch 3 retry — the upgrade object already exists → {:ok, :already_upgraded}", ctx do
    seed_prior!(ctx, %{"v" => "1"}, "role-seed:#{ctx.ws}:#{ctx.name}")

    v2 = %{"v" => "2"}
    upgrade_turn = "role-seed-upgrade:#{ctx.ws}:#{ctx.name}:#{ContentHash.of(v2)}"

    # A prior boot wrote the upgrade OBJECT but crashed before repointing.
    {:ok, _} =
      %{
        id: Ecto.UUID.generate(),
        workspace_uri: ctx.ws,
        subject_uri: ctx.subject,
        key: @key,
        body: v2,
        content_hash: ContentHash.of(v2),
        created_by: "entity://system/user/admin",
        source_turn_id: upgrade_turn
      }
      |> ConfigObject.changeset()
      |> EzagentCore.Repo.insert()

    assert {:ok, :already_upgraded} =
             ConfigStore.seed_object_upsert(attrs(ctx, v2, %{seed_family_prefix: "role-seed"}))
  end

  # ---- Branch 4: non-seed override survives (prefix present) -----------------

  test "branch 4 — body differs + NON-seed turn (prefix present) → {:ok, :exists}", ctx do
    %ConfigObject{id: override_id} =
      seed_prior!(ctx, %{"v" => "override"}, "override-#{System.unique_integer([:positive])}")

    assert {:ok, :exists} =
             ConfigStore.seed_object_upsert(
               attrs(ctx, %{"v" => "seed"}, %{seed_family_prefix: "role-seed"})
             )

    # The override is untouched — no new object, pointer unmoved.
    assert {:ok, %ConfigObject{id: ^override_id, body: %{"v" => "override"}}} = resolve(ctx)
    assert 1 == count(ctx)
  end

  # ---- §5.2 always-upgrade mode (NO prefix): non-seed object IS upgraded ------

  test "no prefix — body differs + NON-seed turn → UPGRADE (§5.2 always-upgrade)", ctx do
    seed_prior!(ctx, %{"v" => "admin-edit"}, "definition-write:#{ctx.ws}:#{ctx.name}")

    # DefinitionRegistry passes NO :seed_family_prefix — an admin-edited (non-seed)
    # object is still re-promoted to the built-in on a hash difference.
    assert {:ok, :seeded} = ConfigStore.seed_object_upsert(attrs(ctx, %{"v" => "builtin"}, %{}))

    assert {:ok, %ConfigObject{body: %{"v" => "builtin"}, source_turn_id: turn}} = resolve(ctx)
    assert String.starts_with?(turn, "role-seed-upgrade:")
  end
end
