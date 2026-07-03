defmodule Ezagent.Socialware.ConformanceTest do
  @moduledoc """
  T2-3 — `Ezagent.Socialware.Conformance.check/2`: a well-formed definition
  passes all assertions; a definition naming a nonexistent recipe / prompt
  template ref / duplicate role_name goes RED with the assertion that caught it.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry}

  @workspace_uri Ezagent.URI.new!("workspace://system")
  @actor Ezagent.URI.new!("entity://system/user/admin")

  defp uniq, do: System.unique_integer([:positive])

  defp write_def(attrs) do
    {:ok, definition} = Definition.new(attrs)

    {:ok, _obj} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace_uri,
        caller_workspace_uri: @workspace_uri,
        actor_uri: @actor
      )

    definition
  end

  defp seed_recipe(n) do
    name = "t2-conf-recipe-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}]
      })

    name
  end

  test "a well-formed definition (real recipe, valid prompt ref) passes" do
    n = uniq()
    recipe = seed_recipe(n)

    definition =
      write_def(%{
        name: "t2-conf-ok-#{n}",
        agents: [%{recipe: recipe, role_name: "greeter-#{n}"}],
        prompt_templates: %{"hop" => "relay: {body}"},
        routing_rules: [
          %{
            receivers: ["greeter-#{n}"],
            matcher: %{"type" => "mention", "value" => "x"},
            prompt_template_ref: "hop"
          }
        ]
      })

    assert :ok = Conformance.check(definition, @workspace_uri)
  end

  test "an unknown agent recipe fails agent_recipes_resolve" do
    n = uniq()

    definition =
      write_def(%{
        name: "t2-conf-badrecipe-#{n}",
        agents: [%{recipe: "no-such-recipe-#{n}", role_name: "r-#{n}"}]
      })

    assert {:error, failures} = Conformance.check(definition, @workspace_uri)
    assert Enum.any?(failures, &match?({:agent_recipes_resolve, {:unknown_agent_recipe, _}}, &1))
  end

  test "an unknown prompt_template_ref fails prompt_template_refs_valid" do
    n = uniq()

    definition =
      write_def(%{
        name: "t2-conf-badref-#{n}",
        routing_rules: [
          %{
            receivers: ["$session_members"],
            matcher: %{"type" => "mention", "value" => "x"},
            prompt_template_ref: "does-not-exist"
          }
        ]
      })

    assert {:error, failures} = Conformance.check(definition, @workspace_uri)

    assert Enum.any?(
             failures,
             &match?({:prompt_template_refs_valid, {:unknown_prompt_template_ref, _}}, &1)
           )
  end

  test "duplicate agent role_names fail agent_caps_and_role_uniqueness" do
    n = uniq()
    recipe = seed_recipe(n)

    definition =
      write_def(%{
        name: "t2-conf-duprole-#{n}",
        agents: [
          %{recipe: recipe, role_name: "dup-#{n}"},
          %{recipe: recipe, role_name: "dup-#{n}"}
        ]
      })

    assert {:error, failures} = Conformance.check(definition, @workspace_uri)

    assert Enum.any?(
             failures,
             &match?({:agent_caps_and_role_uniqueness, {:duplicate_agent_role_name, _}}, &1)
           )
  end
end
