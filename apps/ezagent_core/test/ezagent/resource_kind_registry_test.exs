defmodule Ezagent.ResourceKindRegistryTest do
  @moduledoc """
  Tests for `Ezagent.ResourceKindRegistry` (df-tech kanban-clean) — the
  `resource`-scheme analogue of `AgentFlavorRegistry`: a declarative
  `resource type → kind_module` map populated by `Ezagent.Plugin.boot/1`
  and read by the domain-owned `resource` SpawnRegistry dispatcher.
  """

  use ExUnit.Case, async: false

  alias Ezagent.ResourceKindRegistry

  # Opaque dummy Kind module — the registry stores it without
  # dereferencing it.
  defmodule DummyKind do
  end

  describe "register/2 + lookup/2 + list_all/0" do
    test "registers a {type, kind_module} pair and looks it up" do
      type = "rkr-a-#{System.unique_integer([:positive])}"

      assert :ok = ResourceKindRegistry.register(type, DummyKind)
      assert {:ok, DummyKind} = ResourceKindRegistry.lookup(type)
    end

    test "lookup/1 returns :error for an unregistered type" do
      assert :error =
               ResourceKindRegistry.lookup("rkr-never-#{System.unique_integer([:positive])}")
    end

    test "list_all/0 includes a registered pair" do
      type = "rkr-list-#{System.unique_integer([:positive])}"
      :ok = ResourceKindRegistry.register(type, DummyKind)

      assert {^type, DummyKind} =
               Enum.find(ResourceKindRegistry.list_all(), fn {t, _} -> t == type end)
    end

    test "re-registering an identical pair is idempotent" do
      type = "rkr-dup-#{System.unique_integer([:positive])}"

      assert :ok = ResourceKindRegistry.register(type, DummyKind)
      assert :ok = ResourceKindRegistry.register(type, DummyKind)
    end

    test "re-registering a type with a different module raises" do
      type = "rkr-collide-#{System.unique_integer([:positive])}"
      :ok = ResourceKindRegistry.register(type, DummyKind)

      err =
        assert_raise ArgumentError, fn ->
          ResourceKindRegistry.register(type, __MODULE__)
        end

      assert err.message =~ type
    end
  end
end
