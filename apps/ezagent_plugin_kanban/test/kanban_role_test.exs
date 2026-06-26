defmodule EzagentPluginKanban.KanbanRoleTest do
  @moduledoc """
  K1 acceptance — the `kanban-manager` role recipe + `roles/0` registration
  (RF-4), the kanban-as-role gate.

  The single combined gate (`Role.new(recipe)` succeeds with the discriminating
  fields) catches the three plan-folded review corrections at once:

    * BLOCKER-1 — `behaviors: [Ezagent.Behavior.Kanban]` ONLY (NOT `Connectors`,
      which is not a Behavior); all 24 actions resolve through `Behavior.Kanban`.
    * HIGH-1   — `requested_caps` are cap-template MAPS `%{behavior:, action:}`,
      not bare atoms (`Role.new/1` `canon_cap` rejects non-maps).
    * BLOCKER-2 — `passive: true` flows through `Role.new/1` onto `%Role{}`.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Role
  alias Ezagent.{RoleRegistry, Behavior.Kanban}
  alias EzagentPluginKanban.Application, as: KanbanApp

  @recipe_name "kanban-manager"

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    :ok
  end

  test "kanban-manager recipe is in roles/0" do
    assert KanbanApp.kanban_manager_recipe() in KanbanApp.roles(),
           "roles/0 must publish the kanban-manager recipe (RF-4 boot registration)"
  end

  test "RF-4 boot registration — roles/0 → RoleRegistry.register → lookup round-trip" do
    # This is EXACTLY what `Ezagent.Plugin.publish/1` does at boot
    # (plugin.ex: `Enum.each(plugin_module.roles(), &RoleRegistry.register/1)`).
    # Proves the "register at boot" half of RF-4: after the publish loop runs,
    # `RoleRegistry.lookup("kanban-manager")` returns the validated recipe.
    # register/1 is idempotent for an identical recipe (same name + same %Role{}
    # → :ok), so this is safe whether or not the plugin's boot already ran it.
    Enum.each(KanbanApp.roles(), fn recipe -> :ok = RoleRegistry.register(recipe) end)

    assert {:ok, %Role{name: @recipe_name, behaviors: [Kanban], passive: true}} =
             RoleRegistry.lookup(@recipe_name)
  end

  test "Role.new/1 accepts the recipe with the discriminating fields (K1 combined gate)" do
    recipe = KanbanApp.kanban_manager_recipe()

    assert {:ok, %Role{} = role} = Role.new(recipe)

    # BLOCKER-1: behaviors is EXACTLY [Behavior.Kanban] — Connectors is not a
    # Behavior and must NOT appear; the 25 actions all resolve through Kanban.
    assert role.behaviors == [Kanban]

    # BLOCKER-2: passive flows through onto the struct.
    assert role.passive == true

    assert role.name == @recipe_name

    # HIGH-1: requested_caps are atom-keyed cap-template MAPS — one per action,
    # carrying ONLY {behavior, action} (no `kind` materialization axis). The
    # count + shape pin the recipe; `==` on the whole struct would be brittle.
    actions = Kanban.actions()
    assert length(actions) == 25, "kanban declares exactly 25 actions (B1 加了 bind_session)"
    assert length(role.requested_caps) == 25

    assert Enum.all?(role.requested_caps, fn cap ->
             is_map(cap) and cap.behavior == Kanban and cap.action in actions and
               not Map.has_key?(cap, :kind)
           end),
           "every requested_cap must be %{behavior: Behavior.Kanban, action: <action>}"

    # The cap set covers EVERY declared action (no missing / extra).
    assert MapSet.new(role.requested_caps, & &1.action) == MapSet.new(actions)
  end

  test "a recipe with bare-atom caps is REJECTED (HIGH-1 guard)" do
    bad = %{
      name: @recipe_name,
      passive: true,
      behaviors: [Kanban],
      requested_caps: [:add_node]
    }

    assert {:error, {:invalid_role_field, :requested_caps, :add_node}} = Role.new(bad)
  end
end
