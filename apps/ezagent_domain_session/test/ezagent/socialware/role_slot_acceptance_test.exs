defmodule Ezagent.Socialware.RoleSlotAcceptanceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry}
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @workspace_uri Ezagent.URI.new!("workspace://system")
  @actor Ezagent.URI.new!("entity://system/user/admin")

  test "definition declarations contain role slots, not participant instance URIs" do
    assert {:ok, definition} =
             Definition.new(%{
               name: "role-slot-app",
               roles: [
                 %{role_name: "bot", fill: :agent, recipe: "support-bot", flavor: "curl"},
                 %{role_name: "visitor", fill: :human}
               ],
               routing_rules: [
                 %{
                   matcher: %{"type" => "always"},
                   receivers: ["bot"],
                   rule_set: "default",
                   position: 0
                 }
               ],
               visibility_policy: %{publish_policy: :auto, web_anon_access: true}
             })

    body = Definition.body(definition)

    assert body.roles == [
             %{
               "role_name" => "bot",
               "fill" => "agent",
               "recipe" => "support-bot",
               "flavor" => "curl",
               "credential_admission" => "immediate"
             },
             %{"role_name" => "visitor", "fill" => "human"}
           ]

    refute Map.has_key?(body, :agents)
    refute Map.has_key?(body, :members)
    assert body.owner_policy == %{"type" => "installer"}
  end

  test "retired direct participant and fixed owner declarations fail loud" do
    assert {:error, {:retired_socialware_definition_field, :members}} =
             Definition.new(%{
               name: "stolen-member",
               members: [%{role_name: "bot", uri: "entity://acme/agent/stolen"}]
             })

    assert {:error, {:socialware_definition_declares_instance_uri, _}} =
             Definition.new(%{
               name: "stolen-role-uri",
               roles: [
                 %{
                   role_name: "bot",
                   fill: :agent,
                   recipe: "support-bot",
                   flavor: "curl",
                   uri: "entity://acme/agent/stolen"
                 }
               ]
             })

    assert {:error, {:socialware_definition_declares_owner_uri, _}} =
             Definition.new(%{
               name: "fixed-owner",
               owner_policy: %{type: :fixed, uri: Ezagent.Entity.User.admin_uri()}
             })
  end

  test "agent materialization allocates fresh uuid instance URIs" do
    workspace_uri = Ezagent.URI.workspace("role-slot-acceptance")

    first = DefinitionAgents.planned_agent_uri(workspace_uri)
    second = DefinitionAgents.planned_agent_uri(workspace_uri)

    assert first.scheme == "entity"
    assert String.contains?(first.path, "/agent/")
    assert {:ok, _uuid} = first.path |> Path.basename() |> Ecto.UUID.cast()
    refute URI.to_string(first) == URI.to_string(second)
  end

  test "legit recipe plus human-slot definition passes role conformance" do
    recipe = "role-slot-acceptance-recipe-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Ezagent.Agent.RecipeRegistry.seed_role_if_absent(%{
        name: recipe,
        requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}],
        skills: []
      })

    assert {:ok, definition} =
             Definition.new(%{
               name: "role-slot-conformance",
               roles: [
                 %{role_name: "bot", fill: :agent, recipe: recipe, flavor: "curl"},
                 %{role_name: "visitor", fill: :human}
               ],
               routing_rules: [
                 %{
                   matcher: %{"type" => "always"},
                   receivers: ["bot"],
                   rule_set: "default",
                   position: 0
                 }
               ],
               prompt_templates: %{"answer" => "Use the context."}
             })

    {:ok, _obj} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace_uri,
        caller_workspace_uri: @workspace_uri,
        actor_uri: @actor
      )

    assert :ok = Conformance.check(definition, @workspace_uri)
  end
end
