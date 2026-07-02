defmodule Ezagent.Socialware.DefinitionTest do
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.Definition

  # A real new-style ActionSet module, used as a stand-in view behavior.
  @view_mod Ezagent.Behavior.Surface

  describe "agents field (T2-1, shape-only validation)" do
    test "accepts a list of %{recipe, role_name} with atom keys" do
      assert {:ok, %Definition{agents: agents}} =
               Definition.new(%{
                 name: "hello",
                 agents: [%{recipe: "hello-greeter", role_name: "greeter"}]
               })

      assert agents == [%{recipe: "hello-greeter", role_name: "greeter"}]
    end

    test "accepts string keys (persisted JSON round-trip) and normalizes to atom keys" do
      assert {:ok, %Definition{agents: agents}} =
               Definition.new(%{
                 "name" => "hello",
                 "agents" => [%{"recipe" => "hello-greeter", "role_name" => "greeter"}]
               })

      assert agents == [%{recipe: "hello-greeter", role_name: "greeter"}]
    end

    test "defaults to [] when absent" do
      assert {:ok, %Definition{agents: []}} = Definition.new(%{name: "hello"})
    end

    test "rejects a non-list agents value" do
      assert {:error, {:invalid_socialware_definition_field, :agents, _}} =
               Definition.new(%{name: "hello", agents: %{recipe: "x", role_name: "y"}})
    end

    test "rejects an agent with a blank recipe" do
      assert {:error, {:invalid_socialware_agent, _}} =
               Definition.new(%{name: "hello", agents: [%{recipe: "", role_name: "greeter"}]})
    end

    test "rejects an agent with a missing role_name" do
      assert {:error, {:invalid_socialware_agent, _}} =
               Definition.new(%{name: "hello", agents: [%{recipe: "hello-greeter"}]})
    end

    test "does NOT resolve recipe existence in new/1 (shape only)" do
      # a wholly nonexistent recipe name is still accepted at the shape boundary
      assert {:ok, %Definition{}} =
               Definition.new(%{
                 name: "hello",
                 agents: [%{recipe: "no-such-recipe-anywhere", role_name: "ghost"}]
               })
    end

    test "body/1 JSON-serializes agents as string-keyed maps" do
      {:ok, definition} =
        Definition.new(%{
          name: "hello",
          agents: [%{recipe: "hello-greeter", role_name: "greeter"}]
        })

      body = Definition.body(definition)
      assert body.agents == [%{"recipe" => "hello-greeter", "role_name" => "greeter"}]
    end
  end

  describe "views field (T2-2a, views-as-behavior)" do
    test "accepts a list of view ActionSet modules and round-trips through body/1" do
      {:ok, %Definition{views: views} = d} =
        Definition.new(%{name: "hello", views: [@view_mod]})

      assert views == [@view_mod]

      body = Definition.body(d)
      assert body.views == [Atom.to_string(@view_mod)]
      assert {:ok, %Definition{views: ^views}} = Definition.new(body)
    end

    test "views enter behaviors/1 between Session and shape" do
      {:ok, d} =
        Definition.new(%{
          name: "hello",
          views: [@view_mod],
          shape: [Ezagent.Behavior.Session]
        })

      behaviors = Definition.behaviors(d)
      assert Ezagent.Behavior.Session in behaviors
      assert @view_mod in behaviors
      # Session is first; the view precedes remaining shape/bases.
      assert hd(behaviors) == Ezagent.Behavior.Session
    end

    test "rejects a non-loaded / non-behavior view module" do
      assert {:error, {:invalid_socialware_behavior, _}} =
               Definition.new(%{name: "hello", views: ["Not.A.Real.Module"]})
    end

    test "defaults views to []" do
      assert {:ok, %Definition{views: []}} = Definition.new(%{name: "hello"})
    end
  end

  describe "round-trip" do
    test "new/1 -> body/1 -> new/1 round-trips agents" do
      {:ok, d1} =
        Definition.new(%{
          name: "hello",
          agents: [%{recipe: "hello-greeter", role_name: "greeter"}]
        })

      body = Definition.body(d1)
      assert {:ok, d2} = Definition.new(body)
      assert d2.agents == d1.agents
    end
  end
end
