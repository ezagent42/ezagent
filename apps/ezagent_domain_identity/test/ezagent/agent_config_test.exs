defmodule Ezagent.AgentConfigTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentConfig, CreatorGrant}
  alias Ezagent.Entity.Agent
  alias Ezagent.Socialware.{ConfigObject, ConfigProjection, ConfigStore}
  alias EzagentCore.Repo

  @default_key "advisor.behavior"

  setup do
    name = "ac-#{System.unique_integer([:positive])}"
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)
    workspace = Ezagent.Capability.workspace_of(agent)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(agent, workspace)

    manager = grant_manage_cap(agent, workspace)

    %{agent: agent, workspace: workspace, manager: manager}
  end

  test "read_cascade returns stable empty default key shape", %{agent: agent, manager: manager} do
    assert {:ok, cascade} = AgentConfig.read_cascade(agent, manager.uri, manager.caps)

    assert cascade.agent_uri == URI.to_string(agent)
    assert cascade.default_key == @default_key
    assert cascade.layer_order == ["workspace", "user", "session"]

    assert [
             %{
               key: @default_key,
               effective_body: %{},
               editable: true,
               editable_layer: "user",
               layers: %{"workspace" => nil, "user" => nil, "session" => nil}
             }
           ] = cascade.keys
  end

  test "apply_delta creates and reads a user-layer config object", %{
    agent: agent,
    manager: manager
  } do
    assert {:ok, %{config_id: cid, previous_config_id: nil}} =
             AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
               patch: %{"tone" => "decisive"},
               turn_id: turn_id("create")
             })

    assert {:ok, cascade} = AgentConfig.read_cascade(agent, manager.uri, manager.caps)
    [state] = cascade.keys

    assert state.effective_body == %{"tone" => "decisive"}
    assert state.layers["user"].config_id == cid
    assert state.layers["user"].body == %{"tone" => "decisive"}
  end

  test "read_cascade includes dynamic pointer keys plus the default key", %{
    agent: agent,
    manager: manager
  } do
    assert {:ok, _} =
             AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
               key: "model.settings",
               patch: %{"model" => "gpt-test"},
               turn_id: turn_id("dynamic")
             })

    assert {:ok, cascade} = AgentConfig.read_cascade(agent, manager.uri, manager.caps)
    assert Enum.map(cascade.keys, & &1.key) == [@default_key, "model.settings"]
  end

  test "apply_delta updates with shallow merge semantics", %{agent: agent, manager: manager} do
    {:ok, %{config_id: first}} =
      AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
        patch: %{"tone" => "neutral", "soul_md" => "# Soul"},
        turn_id: turn_id("merge-a")
      })

    {:ok, %{config_id: second, previous_config_id: ^first}} =
      AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
        patch: %{"tone" => "decisive"},
        turn_id: turn_id("merge-b")
      })

    assert second != first
    assert {:ok, state} = AgentConfig.read_key(agent, @default_key, manager.uri, manager.caps)
    assert state.effective_body == %{"tone" => "decisive", "soul_md" => "# Soul"}
  end

  test "delete_path removes a field by writing a new immutable object", %{
    agent: agent,
    manager: manager
  } do
    {:ok, %{config_id: first}} =
      AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
        patch: %{"tone" => "neutral", "soul_md" => "# Soul"},
        turn_id: turn_id("delete-a")
      })

    count_before_delete = config_object_count()

    assert {:ok, %{config_id: second, previous_config_id: ^first}} =
             AgentConfig.delete_path(agent, manager.uri, manager.caps, %{
               path: ["tone"],
               turn_id: turn_id("delete-b")
             })

    assert second != first
    assert config_object_count() == count_before_delete + 1
    assert {:ok, _old_object} = ConfigStore.fetch_object(first)

    assert {:ok, state} = AgentConfig.read_key(agent, @default_key, manager.uri, manager.caps)
    assert state.effective_body == %{"soul_md" => "# Soul"}
  end

  test "repoint rolls a key back to an existing in-scope object", %{
    agent: agent,
    manager: manager
  } do
    {:ok, %{config_id: first}} =
      AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
        patch: %{"tone" => "A"},
        turn_id: turn_id("repoint-a")
      })

    {:ok, %{config_id: second}} =
      AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
        patch: %{"tone" => "B"},
        turn_id: turn_id("repoint-b")
      })

    assert {:ok, %{config_id: ^first, previous_config_id: ^second}} =
             AgentConfig.repoint(agent, manager.uri, manager.caps, %{
               config_id: first
             })

    assert {:ok, state} = AgentConfig.read_key(agent, @default_key, manager.uri, manager.caps)
    assert state.effective_body == %{"tone" => "A"}
  end

  test "mutation is denied without the agent manage-cap", %{agent: agent} do
    stranger = Ezagent.URI.entity(:team_alpha, :user, "stranger")

    assert {:error, :unauthorized} =
             AgentConfig.apply_delta(agent, stranger, MapSet.new(), %{
               patch: %{"tone" => "denied"},
               turn_id: turn_id("denied")
             })
  end

  test "manage-cap for another agent does not authorize mutation", %{
    agent: agent,
    workspace: workspace
  } do
    other = Ezagent.URI.entity(:team_alpha, :agent, "other-#{System.unique_integer([:positive])}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: other, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(other, workspace)
    other_manager = grant_manage_cap(other, workspace)

    assert {:error, :unauthorized} =
             AgentConfig.apply_delta(agent, other_manager.uri, other_manager.caps, %{
               patch: %{"tone" => "denied"},
               turn_id: turn_id("wrong-cap")
             })
  end

  test "read_cascade is denied without the agent manage-cap", %{agent: agent} do
    stranger = Ezagent.URI.entity(:team_alpha, :user, "stranger")

    assert {:error, :unauthorized} =
             AgentConfig.read_cascade(agent, stranger, MapSet.new())
  end

  test "read_key is denied without the agent manage-cap", %{agent: agent} do
    stranger = Ezagent.URI.entity(:team_alpha, :user, "stranger")

    assert {:error, :unauthorized} =
             AgentConfig.read_key(agent, @default_key, stranger, MapSet.new())
  end

  test "manage-cap for another agent does not authorize read_cascade", %{
    agent: agent,
    workspace: workspace
  } do
    other = Ezagent.URI.entity(:team_alpha, :agent, "other-#{System.unique_integer([:positive])}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: other, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(other, workspace)
    other_manager = grant_manage_cap(other, workspace)

    assert {:error, :unauthorized} =
             AgentConfig.read_cascade(agent, other_manager.uri, other_manager.caps)
  end

  test "manage-cap for another agent does not authorize read_key", %{
    agent: agent,
    workspace: workspace
  } do
    other = Ezagent.URI.entity(:team_alpha, :agent, "other-#{System.unique_integer([:positive])}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: other, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(other, workspace)
    other_manager = grant_manage_cap(other, workspace)

    assert {:error, :unauthorized} =
             AgentConfig.read_key(agent, @default_key, other_manager.uri, other_manager.caps)
  end

  test "manage-cap holder reads the cascade", %{agent: agent, manager: manager} do
    {:ok, %{config_id: cid}} =
      AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
        patch: %{"tone" => "allowed"},
        turn_id: turn_id("read-allow")
      })

    assert {:ok, cascade} = AgentConfig.read_cascade(agent, manager.uri, manager.caps)
    assert cascade.agent_uri == URI.to_string(agent)
    [state] = cascade.keys
    assert state.effective_body == %{"tone" => "allowed"}
    assert state.layers["user"].config_id == cid

    assert {:ok, key_state} = AgentConfig.read_key(agent, @default_key, manager.uri, manager.caps)
    assert key_state.effective_body == %{"tone" => "allowed"}
  end

  test "soul_md writes materialize to CLAUDE.md through ConfigProjection", %{
    agent: agent,
    workspace: workspace,
    manager: manager
  } do
    soul = "# New Soul\n\nOperate carefully.\n"

    assert {:ok, %{config_id: cid}} =
             AgentConfig.apply_delta(agent, manager.uri, manager.caps, %{
               patch: %{"soul_md" => soul},
               turn_id: turn_id("soul")
             })

    object_uri = ConfigProjection.object_uri(workspace, cid)
    assert {:ok, dir} = ConfigProjection.resolve_config_dir(object_uri)

    try do
      assert File.read!(Path.join(dir, "CLAUDE.md")) == soul
    after
      File.rm_rf(dir)
    end
  end

  defp grant_manage_cap(agent, workspace) do
    manager = Ezagent.URI.entity(:team_alpha, :user, "mgr-#{System.unique_integer([:positive])}")
    cap = CreatorGrant.manage_cap(:agent, agent, workspace, manager)
    %{uri: manager, caps: MapSet.new([cap])}
  end

  defp turn_id(label), do: "console:#{label}:#{System.unique_integer([:positive])}"

  defp config_object_count, do: Repo.aggregate(ConfigObject, :count, :id)
end
