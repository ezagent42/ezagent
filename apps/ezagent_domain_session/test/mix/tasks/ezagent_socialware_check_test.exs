defmodule Mix.Tasks.Ezagent.Socialware.CheckTest do
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureIO

  alias Ezagent.Socialware.{Definition, DefinitionRegistry}

  @workspace_uri Ezagent.URI.workspace(:system)
  @actor_uri Ezagent.Entity.User.admin_uri()
  @task_path Path.expand("../../../lib/mix/tasks/ezagent.socialware.check.ex", __DIR__)

  setup do
    :ok = DefinitionRegistry.seed_builtin_definitions()
    Mix.Task.reenable("ezagent.socialware.check")
    :ok
  end

  test "gate checks a third published definition instead of narrowing to hardcoded builtins" do
    name = "t8-check-third-#{System.unique_integer([:positive])}"

    {:ok, definition} =
      Definition.new(%{
        name: name,
        roles: [
          %{
            role_name: "broken",
            fill: :agent,
            recipe: "missing-recipe-#{name}",
            flavor: "curl"
          }
        ]
      })

    {:ok, _object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace_uri,
        caller_workspace_uri: @workspace_uri,
        actor_uri: @actor_uri
      )

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/socialware conformance FAILED/, fn ->
          Mix.Task.rerun("ezagent.socialware.check", [])
        end
      end)

    assert output =~ name
    assert output =~ "agent_recipes_resolve"
  end

  test "enumeration path has no function_exported? probe or hardcoded socialware-name fallback" do
    source = File.read!(@task_path)

    refute source =~ "function_exported?(DefinitionRegistry, :list"
    refute source =~ ~s(["chat", "socialware"])
  end
end
