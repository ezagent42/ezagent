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

  test "seeds orchestrator as a built-in socialware Definition using the cc plugin" do
    # Force the orchestrator definition to the CODE version so this assertion is
    # deterministic regardless of what the ambient DB already holds. Under the
    # default no-clobber boot policy (Allen 2026-07-10), a reused DB carrying an
    # older stored orchestrator (e.g. the pre-#1332 `cc` one) is intentionally NOT
    # auto-migrated by `seed_builtin_definitions/0` — applying the code version is
    # an explicit force. This test asserts the code definition's shape, so it
    # forces it first (content-safe append + repoint, rolled back with the sandbox).
    {:ok, _} = DefinitionRegistry.reseed_builtin_definition("orchestrator")

    assert {:ok, definition, _object} =
             DefinitionRegistry.lookup(Ezagent.URI.workspace(:system), "orchestrator")

    # `uses` names the PLUGIN (cc); the orchestrator runs on the `cc-deepseek`
    # provider FLAVOR of that plugin (#1332/#1324) — the built-in role flavor was
    # brought into agreement with the cc-orchestrator AgentTemplate seed.
    assert definition.uses == ["cc"]
    assert definition.views == []
    assert definition.routing_rules == []
    assert definition.orchestrator_template_uri == nil

    assert [
             %{
               role_name: "orchestrator",
               fill: :agent,
               recipe: "orchestrator",
               flavor: "cc-deepseek"
             }
           ] = definition.roles
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

  test "installing an entry socialware recursively installs required socialwares first" do
    n = System.unique_integer([:positive])
    dep_name = "install-required-dep-#{n}"
    app_name = "install-required-app-#{n}"
    session_uri = Ezagent.URI.session(:system, :socialware, "requires-#{n}")

    _dep_object = write_definition!(dep_name, "dep")
    _app_object = write_definition!(app_name, "app", requires: [dep_name])

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [app_name]},
               @actor_uri
             )

    assert Installation.installed?(session_uri, dep_name)
    assert Installation.installed?(session_uri, app_name)
  end

  test "re-seeding an already installed dependent still ensures newly added requirements" do
    n = System.unique_integer([:positive])
    dep_name = "install-idem-dep-#{n}"
    app_name = "install-idem-app-#{n}"
    session_uri = Ezagent.URI.session(:system, :socialware, "requires-idem-#{n}")

    _dep_object = write_definition!(dep_name, "dep")
    _app_v1_object = write_definition!(app_name, "app-v1")

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [app_name]},
               @actor_uri
             )

    refute Installation.installed?(session_uri, dep_name)

    _app_v2_object = write_definition!(app_name, "app-v2", requires: [dep_name])

    assert :ok =
             Installation.repoint_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [app_name]},
               @actor_uri
             )

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [app_name]},
               @actor_uri
             )

    assert Installation.installed?(session_uri, dep_name)
    assert Installation.installed?(session_uri, app_name)
  end

  test "repoint preflights reverse dependents and rejects before flipping incompatible dependency" do
    n = System.unique_integer([:positive])
    dep_name = "install-repoint-dep-#{n}"
    app_name = "install-repoint-app-#{n}"
    session_uri = Ezagent.URI.session(:system, :socialware, "requires-repoint-#{n}")

    dep_r1 =
      write_definition!(dep_name, "dep-r1",
        roles: [%{role_name: "#{dep_name}:worker", fill: :human}]
      )

    _app_object =
      write_definition!(app_name, "app",
        requires: [dep_name],
        roles: [%{role_name: "#{app_name}:entry", fill: :human}],
        routing_rules: [
          %{
            matcher: %{"type" => "from_role", "arg" => "#{app_name}:entry"},
            receivers: ["#{dep_name}:worker"]
          }
        ]
      )

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [app_name]},
               @actor_uri
             )

    assert pointed_definition_id(session_uri, dep_name) == dep_r1.id
    _dep_r2 = write_definition!(dep_name, "dep-r2", roles: [])

    assert {:error, {:repoint_blocked, ^dep_name, blocked}} =
             Installation.repoint_template_installs(
               session_uri,
               @workspace_uri,
               %{installs: [dep_name]},
               @actor_uri
             )

    assert [{^app_name, failures}] = blocked
    assert Enum.any?(failures, &match?({:routing_receivers_resolve, _}, &1))
    assert pointed_definition_id(session_uri, dep_name) == dep_r1.id
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

  defp write_definition!(name, marker, overrides \\ []) do
    attrs =
      %{
        name: name,
        bases: [Ezagent.ActionSet.Session],
        prompt_templates: %{"marker" => marker}
      }
      |> Map.merge(Map.new(overrides))

    {:ok, definition} =
      Definition.new(attrs)

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
