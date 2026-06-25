defmodule Ezagent.RoleRegistryTest do
  @moduledoc """
  Tests for `Ezagent.RoleRegistry` (role-foundation RF-4) — the code-seed
  `role name → validated %Role{} recipe` ETS map.
  """

  use ExUnit.Case, async: false

  setup do
    name = "rr-#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(Ezagent.RoleRegistry.table(), name) end)
    {:ok, name: name}
  end

  test "register/1 stores a recipe map looked up by name as a validated Role", %{name: name} do
    recipe = %{name: name, skills: ["s"], prompt: "p", behaviors: [], requested_caps: []}

    assert :ok == Ezagent.RoleRegistry.register(recipe)

    assert {:ok, %Ezagent.Role{name: ^name, skills: ["s"], prompt: "p"}} =
             Ezagent.RoleRegistry.lookup(name)
  end

  test "lookup/1 returns :error for an unknown name", %{name: name} do
    assert :error == Ezagent.RoleRegistry.lookup("missing-#{name}")
  end

  test "register/1 is idempotent for an identical recipe", %{name: name} do
    recipe = %{name: name, skills: ["s"]}
    assert :ok == Ezagent.RoleRegistry.register(recipe)
    assert :ok == Ezagent.RoleRegistry.register(recipe)
  end

  test "register/1 raises on a conflicting recipe under the same name", %{name: name} do
    assert :ok == Ezagent.RoleRegistry.register(%{name: name, skills: ["a"]})

    assert_raise ArgumentError, ~r/already registered/, fn ->
      Ezagent.RoleRegistry.register(%{name: name, skills: ["b"]})
    end
  end

  test "register/1 rejects a nameless recipe (cannot be keyed)" do
    assert_raise ArgumentError, ~r/non-empty :name/, fn ->
      Ezagent.RoleRegistry.register(%{skills: ["s"]})
    end
  end

  test "register/1 validates the recipe through Role.new/1", %{name: name} do
    # `behaviors: "not-a-list"` fails `Ezagent.Role.new/1` shape validation.
    assert_raise ArgumentError, ~r/Role.new/, fn ->
      Ezagent.RoleRegistry.register(%{name: name, behaviors: "not-a-list"})
    end
  end

  test "list_all/0 includes a registered role", %{name: name} do
    :ok = Ezagent.RoleRegistry.register(%{name: name, skills: []})
    assert Enum.any?(Ezagent.RoleRegistry.list_all(), fn {n, _} -> n == name end)
  end
end
