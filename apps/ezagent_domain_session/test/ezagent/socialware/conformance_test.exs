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
        roles: [%{role_name: "greeter-#{n}", fill: :agent, recipe: recipe, flavor: "curl"}],
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
        roles: [
          %{
            role_name: "r-#{n}",
            fill: :agent,
            recipe: "no-such-recipe-#{n}",
            flavor: "curl"
          }
        ]
      })

    assert {:error, failures} = Conformance.check(definition, @workspace_uri)
    assert Enum.any?(failures, &match?({:agent_recipes_resolve, {:unknown_agent_recipe, _}}, &1))
  end

  test "an unknown prompt_template_ref fails prompt_template_refs_valid" do
    n = uniq()

    definition =
      write_def(%{
        name: "t2-conf-badref-#{n}",
        roles: [%{role_name: "reader-#{n}", fill: :human}],
        routing_rules: [
          %{
            receivers: ["reader-#{n}"],
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
        roles: [
          %{role_name: "dup-#{n}", fill: :agent, recipe: recipe, flavor: "curl"},
          %{role_name: "dup-#{n}", fill: :human}
        ]
      })

    assert {:error, failures} = Conformance.check(definition, @workspace_uri)

    assert Enum.any?(
             failures,
             &match?({:agent_caps_and_role_uniqueness, {:duplicate_role_name, _}}, &1)
           )
  end

  test "non-role receivers fail routing_receivers_resolve" do
    n = uniq()

    definition =
      write_def(%{
        name: "t2-conf-non-role-receiver-#{n}",
        roles: [%{role_name: "bot-#{n}", fill: :human}],
        routing_rules: [
          %{
            receivers: ["$session_members"],
            matcher: %{"type" => "mention", "value" => "x"}
          }
        ]
      })

    assert {:error, failures} = Conformance.check(definition, @workspace_uri)

    assert Enum.any?(
             failures,
             &match?(
               {:routing_receivers_resolve, {:socialware_receiver_not_a_role, [_]}},
               &1
             )
           )
  end

  test "role-DAG rejects unpredicated cycles" do
    n = uniq()

    definition =
      write_def(%{
        name: "t2-conf-hard-cycle-#{n}",
        roles: [
          %{role_name: "viewer-#{n}", fill: :human},
          %{role_name: "responser-#{n}", fill: :human}
        ],
        routing_rules: [
          %{
            matcher: %{"type" => "from_role", "arg" => "viewer-#{n}"},
            receivers: ["responser-#{n}"]
          },
          %{
            matcher: %{"type" => "from_role", "arg" => "responser-#{n}"},
            receivers: ["viewer-#{n}"]
          }
        ]
      })

    assert {:error, failures} = Conformance.check(definition, @workspace_uri)

    assert Enum.any?(
             failures,
             &match?({:routing_role_dag, {:unpredicated_cycle, _}}, &1)
           )
  end

  test "role-DAG warns on predicated cycles, double delivery, and dead roles" do
    n = uniq()

    definition =
      write_def(%{
        name: "t2-conf-warn-dag-#{n}",
        roles: [
          %{role_name: "viewer-#{n}", fill: :human},
          %{role_name: "responser-#{n}", fill: :human},
          %{role_name: "builder-#{n}", fill: :human},
          %{role_name: "dead-#{n}", fill: :human}
        ],
        routing_rules: [
          %{
            matcher: %{"type" => "from_role", "arg" => "viewer-#{n}"},
            receivers: ["responser-#{n}"]
          },
          %{
            matcher: %{
              "type" => "and",
              "items" => [
                %{"type" => "from_role", "arg" => "responser-#{n}"},
                %{"type" => "text_matches", "arg" => "^\\[need-build\\]"}
              ]
            },
            receivers: ["viewer-#{n}"]
          },
          %{
            matcher: %{"type" => "from_role", "arg" => "responser-#{n}"},
            receivers: ["builder-#{n}"]
          }
        ]
      })

    assert {:ok, warnings} = Conformance.check_with_warnings(definition, @workspace_uri)
    assert Enum.any?(warnings, &match?({:routing_role_dag, {:predicated_cycle, _}}, &1))
    assert Enum.any?(warnings, &match?({:routing_role_dag, {:double_delivery, _}}, &1))
    assert Enum.any?(warnings, &match?({:routing_role_dag, {:dead_role, _}}, &1))
  end

  test "composite human socialware with no adapter-flavor receiver warns but remains installable" do
    n = uniq()
    native_recipe = seed_recipe("native-#{n}")

    definition =
      write_def(%{
        name: "t2-conf-mute-composite-#{n}",
        roles: [
          %{role_name: "viewer-#{n}", fill: :human},
          %{role_name: "builder-#{n}", fill: :agent, recipe: native_recipe, flavor: "native"}
        ],
        routing_rules: [
          %{
            matcher: %{"type" => "from_role", "arg" => "viewer-#{n}"},
            receivers: ["builder-#{n}"]
          }
        ]
      })

    assert :ok = Conformance.check(definition, @workspace_uri)
    assert {:ok, warnings} = Conformance.check_with_warnings(definition, @workspace_uri)

    assert Enum.any?(
             warnings,
             &match?({:routing_role_dag, {:mute_composite, _}}, &1)
           )
  end

  test "missing manifest uses plugin fails uses_plugins_installed" do
    n = uniq()

    definition =
      write_def(%{
        name: "t2-conf-missing-plugin-#{n}",
        uses: ["no-such-socialware-plugin-#{n}"]
      })

    assert {:error, failures} = Conformance.check(definition, @workspace_uri)

    assert Enum.any?(
             failures,
             &match?({:uses_plugins_installed, {:missing_socialware_plugins, [_]}}, &1)
           )
  end
end
