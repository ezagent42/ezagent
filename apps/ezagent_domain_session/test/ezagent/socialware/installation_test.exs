defmodule Ezagent.Socialware.InstallationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{Definition, DefinitionEditor, DefinitionRegistry, Installation}

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

    assert {:ok, config} = DefinitionEditor.config_for_template(content, Ezagent.URI.workspace(:system))

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

  defp seed_builtins do
    case DefinitionRegistry.seed_builtin_definitions() do
      :ok -> :ok
      {:error, {:socialware_definition_seed_collision, _}} -> :ok
    end
  end
end
