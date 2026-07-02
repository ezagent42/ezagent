defmodule Ezagent.Socialware.DefinitionTest do
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.Definition

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
