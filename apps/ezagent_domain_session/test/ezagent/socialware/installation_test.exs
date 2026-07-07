defmodule Ezagent.Socialware.InstallationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Routing.{Matcher, RuleStore}
  alias Ezagent.Entity.Session

  alias Ezagent.Socialware.{
    ConfigObject,
    ConfigStore,
    Definition,
    DefinitionEditor,
    DefinitionRegistry,
    Installation
  }

  @workspace_uri Ezagent.URI.workspace(:system)
  @actor_uri Ezagent.Entity.User.admin_uri()

  setup do
    :ok = seed_builtins()
  end

  test "defaults absent template installs to the chat definition" do
    assert Installation.installs_from_template(%{}) == ["chat"]

    assert {:ok, behaviors} =
             Installation.behavior_set_for_template(%{}, Ezagent.URI.workspace(:system))

    assert behaviors == Session.chat_behaviors()
  end

  test "resolves socialware behavior set from ConfigStore definitions" do
    assert {:ok, behaviors} =
             Installation.behavior_set_for_template(
               %{installs: ["socialware"]},
               Ezagent.URI.workspace(:system)
             )

    assert behaviors == Session.socialware_behaviors()
  end

  test "rejects unknown installs fail-loud" do
    assert {:error, {:unknown_socialware_install, "bogus"}} =
             Installation.behavior_set_for_template(
               %{installs: ["bogus"]},
               Ezagent.URI.workspace(:system)
             )
  end

  test "install config overlays operator role-slot choices without changing definitions" do
    definition_name = "role-slot-overlay-#{System.unique_integer([:positive])}"

    {:ok, definition} =
      Definition.new(%{
        name: definition_name,
        bases: [Ezagent.ActionSet.Session],
        roles: [
          %{role_name: "orchestrator", fill: :agent, recipe: "orchestrator", flavor: "claude"},
          %{role_name: "reviewer", fill: :agent, recipe: "reviewer", flavor: "claude"}
        ]
      })

    assert {:ok, _object} =
             DefinitionRegistry.write_definition(definition,
               workspace_uri: Ezagent.URI.workspace(:system),
               caller_workspace_uri: Ezagent.URI.workspace(:system),
               actor_uri: Ezagent.Entity.User.admin_uri()
             )

    content = %{
      installs: [
        %{
          ref: definition_name,
          config: %{
            "role_slots" => [
              %{"role_name" => "orchestrator", "mode" => "fresh", "flavor" => "codex"},
              %{
                "role_name" => "reviewer",
                "mode" => "reuse",
                "agent_uri" => "entity://system/agent/reviewer-owned"
              }
            ]
          }
        }
      ]
    }

    assert {:ok, config} =
             DefinitionEditor.config_for_template(content, Ezagent.URI.workspace(:system))

    assert Enum.any?(config.roles, fn
             %{role_name: "orchestrator", fill: :agent, flavor: "codex", install_mode: :fresh} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(config.roles, fn
             %{
               role_name: "reviewer",
               install_mode: :reuse,
               reuse_agent_uri: %URI{scheme: "entity"}
             } ->
               true

             _ ->
               false
           end)
  end

  test "retract_session_installs makes an installed ref absent and allows fresh re-seed" do
    name = "install-retract-#{System.unique_integer([:positive])}"
    session_uri = Ezagent.URI.session(:system, :socialware, "retract-#{name}")

    first_object = write_definition!(name, "first")

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [name]},
               @actor_uri
             )

    assert Installation.installed?(session_uri, name)
    assert pointed_definition_id(session_uri, name) == first_object.id

    assert :ok = Installation.retract_session_installs(session_uri, @actor_uri)
    refute Installation.installed?(session_uri, name)
    assert pointed_install_body(session_uri, name)["removed"] == true

    second_object = write_definition!(name, "second")

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [name]},
               @actor_uri
             )

    assert Installation.installed?(session_uri, name)
    assert pointed_definition_id(session_uri, name) == second_object.id
  end

  test "session rollback removes rule rows and retracts install pointers for the session" do
    name = "rollback-install-#{System.unique_integer([:positive])}"
    session_uri = Ezagent.URI.session(:system, :socialware, "rollback-#{name}")
    table = Ezagent.Routing.Resolver.default_routing_table()

    _object = write_definition!(name, "rollback")

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [name]},
               @actor_uri
             )

    assert {:ok, %RuleStore{}} =
             RuleStore.add(
               table,
               Matcher.always(),
               [Ezagent.Routing.Receiver.role("owner")],
               session_uri,
               source: RuleStore.system_default_source(),
               workspace_uri: @workspace_uri,
               rule_set: "rollback-test",
               position: 0
             )

    assert Installation.installed?(session_uri, name)
    assert Enum.any?(RuleStore.list(table), &(&1.created_by == URI.to_string(session_uri)))

    assert :ok =
             EzagentDomainInstanceMessage.SessionCreator.rollback_session(session_uri, nil,
               owner_uri: @actor_uri,
               workspace_uri: @workspace_uri
             )

    refute Installation.installed?(session_uri, name)
    refute Enum.any?(RuleStore.list(table), &(&1.created_by == URI.to_string(session_uri)))

    assert :ok =
             EzagentDomainInstanceMessage.SessionCreator.rollback_session(session_uri, nil,
               owner_uri: @actor_uri,
               workspace_uri: @workspace_uri
             )
  end

  defp seed_builtins do
    case DefinitionRegistry.seed_builtin_definitions() do
      :ok -> :ok
      {:error, {:socialware_definition_seed_collision, _}} -> :ok
    end
  end

  defp write_definition!(name, marker) do
    {:ok, definition} =
      Definition.new(%{
        name: name,
        bases: [Ezagent.ActionSet.Session],
        prompt_templates: %{"marker" => marker}
      })

    {:ok, object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace_uri,
        caller_workspace_uri: @workspace_uri,
        actor_uri: @actor_uri
      )

    object
  end

  defp pointed_definition_id(session_uri, ref) do
    pointed_install_body(session_uri, ref)["definition_config_id"]
  end

  defp pointed_install_body(session_uri, ref) do
    assert {:ok, %ConfigObject{body: body}} =
             ConfigStore.resolve("session", @workspace_uri, session_uri, "install:#{ref}")

    body
  end
end
