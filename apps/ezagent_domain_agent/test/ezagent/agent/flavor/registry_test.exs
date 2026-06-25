defmodule Ezagent.AgentFlavorRegistryTest do
  @moduledoc "Tests for `Ezagent.AgentFlavorRegistry` (SPEC §6.3)."

  use ExUnit.Case, async: false

  alias Ezagent.AgentFlavorRegistry

  # Distinct dummy modules for the kind / template_class fields. The
  # registry stores them opaquely (PR-1 does not dereference them).
  defmodule DummyKind do
  end

  defmodule DummyTemplateClass do
  end

  describe "register/1 + lookup/1 + list_all/0" do
    test "registers an agent_flavor_decl and looks it up" do
      flavor = "afr-a-#{System.unique_integer([:positive])}"

      assert :ok =
               AgentFlavorRegistry.register(%{
                 flavor: flavor,
                 kind: DummyKind,
                 template_class: DummyTemplateClass
               })

      assert {:ok, %{kind: DummyKind, template_class: DummyTemplateClass}} =
               AgentFlavorRegistry.lookup(flavor)
    end

    test "lookup/1 returns :error for an unregistered flavor" do
      assert :error =
               AgentFlavorRegistry.lookup("afr-never-#{System.unique_integer([:positive])}")
    end

    test "list_all/0 includes a registered flavor" do
      flavor = "afr-list-#{System.unique_integer([:positive])}"

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: DummyKind,
          template_class: DummyTemplateClass
        })

      assert {^flavor, %{kind: DummyKind, template_class: DummyTemplateClass}} =
               Enum.find(AgentFlavorRegistry.list_all(), fn {f, _} -> f == flavor end)
    end

    test "re-registering an identical decl is idempotent" do
      flavor = "afr-dup-#{System.unique_integer([:positive])}"
      decl = %{flavor: flavor, kind: DummyKind, template_class: DummyTemplateClass}

      assert :ok = AgentFlavorRegistry.register(decl)
      assert :ok = AgentFlavorRegistry.register(decl)
    end

    test "re-registering a flavor with a different wiring raises" do
      flavor = "afr-collide-#{System.unique_integer([:positive])}"

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: DummyKind,
          template_class: DummyTemplateClass
        })

      err =
        assert_raise ArgumentError, fn ->
          AgentFlavorRegistry.register(%{
            flavor: flavor,
            kind: __MODULE__,
            template_class: DummyTemplateClass
          })
        end

      assert err.message =~ flavor
    end
  end
end
