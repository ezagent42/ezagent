defmodule Ezagent.Socialware.DefinitionRegistryTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Definition, DefinitionRegistry}

  @system_ws Ezagent.URI.new!("workspace://system")
  @team_a Ezagent.URI.new!("workspace://team-a")
  @team_b Ezagent.URI.new!("workspace://team-b")
  @actor_a Ezagent.URI.new!("entity://team-a/user/alice")

  defp uniq, do: System.unique_integer([:positive])

  defp write!(workspace_uri, attrs) do
    {:ok, definition} = Definition.new(attrs)

    {:ok, object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: workspace_uri,
        caller_workspace_uri: workspace_uri,
        actor_uri: @actor_a,
        # #165: seeding a public catalog def now requires admin authority.
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
      )

    object
  end

  test "list returns own workspace definitions, system definitions, and public definitions" do
    n = uniq()

    own_name = "own-private-#{n}"
    public_name = "public-other-#{n}"
    private_other_name = "private-other-#{n}"
    system_name = "system-#{n}"

    write!(@team_a, %{
      name: own_name,
      title: "Own private",
      description: "local only",
      visibility_policy: %{scope: :private}
    })

    write!(@team_b, %{
      name: public_name,
      title: "Public other",
      description: "visible",
      visibility_policy: %{scope: :public}
    })

    write!(@team_b, %{
      name: private_other_name,
      title: "Private other",
      description: "hidden",
      visibility_policy: %{scope: :private}
    })

    write!(@system_ws, %{
      name: system_name,
      title: "System",
      description: "built in",
      visibility_policy: %{scope: :private}
    })

    rows = DefinitionRegistry.list(@team_a)
    names = Enum.map(rows, & &1.name)

    assert own_name in names
    assert public_name in names
    assert system_name in names
    refute private_other_name in names

    assert %{title: "Public other", description: "visible", public?: true} =
             Enum.find(rows, &(&1.name == public_name))
  end

  test "lookup resolves public definitions from another workspace for read-only install" do
    n = uniq()
    public_name = "lookup-public-other-#{n}"
    private_name = "lookup-private-other-#{n}"

    public_object =
      write!(@team_b, %{
        name: public_name,
        title: "Public lookup",
        visibility_policy: %{scope: :public}
      })

    write!(@team_b, %{
      name: private_name,
      title: "Private lookup",
      visibility_policy: %{scope: :private}
    })

    assert {:ok, %Definition{name: ^public_name}, object} =
             DefinitionRegistry.lookup(@team_a, public_name)

    assert object.id == public_object.id
    assert :error = DefinitionRegistry.lookup(@team_a, private_name)
  end

  test "write_definition rejects a caller-forged cross-workspace write" do
    assert {:error, {:cross_workspace_socialware_definition_write_denied, _}} =
             DefinitionRegistry.write_definition(
               %{name: "forged-#{uniq()}"},
               workspace_uri: @team_b,
               caller_workspace_uri: @team_a,
               actor_uri: @actor_a
             )
  end

  test "write_definition requires explicit workspace and actor" do
    assert {:error, :missing_socialware_definition_workspace} =
             DefinitionRegistry.write_definition(%{name: "missing-ws-#{uniq()}"},
               actor_uri: @actor_a
             )

    assert {:error, :missing_socialware_definition_actor} =
             DefinitionRegistry.write_definition(%{name: "missing-actor-#{uniq()}"},
               workspace_uri: @team_a
             )
  end
end
