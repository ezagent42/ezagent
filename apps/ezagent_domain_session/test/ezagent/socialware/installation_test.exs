defmodule Ezagent.Socialware.InstallationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}

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

  defp seed_builtins do
    case DefinitionRegistry.seed_builtin_definitions() do
      :ok -> :ok
      {:error, {:socialware_definition_seed_collision, _}} -> :ok
    end
  end
end
