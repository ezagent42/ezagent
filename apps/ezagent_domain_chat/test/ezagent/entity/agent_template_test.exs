defmodule Ezagent.Entity.AgentTemplateTest do
  @moduledoc """
  Phase 7 PR 37 — AgentTemplate Kind structural tests.

  These tests pin the Kind contract surface (callbacks, persistence,
  behaviors) so future refactors don't drift the type. End-to-end
  spawn + slice population is covered by Phase 7 PR 40 (`Ezagent.Entity.Agent.spawn/4`
  spawn-from-template flow) which exercises the spawn path.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Entity.AgentTemplate

  test "type_name/0 returns :agent_template" do
    assert AgentTemplate.type_name() == :agent_template
  end

  test "behaviors/0 includes Identity (caps + grant policy live on slice)" do
    behaviors = AgentTemplate.behaviors()
    assert Ezagent.Behavior.Identity in behaviors,
           "AgentTemplate must carry Identity behavior so default_caps + slice " <>
             "edit can use the existing identity dispatch path"
  end

  test "behaviors/0 includes Behavior.Template (Phase 7 completion PR-1 — content slice)" do
    assert Ezagent.Behavior.Template in AgentTemplate.behaviors(),
           "AgentTemplate must carry Behavior.Template so the :template content " <>
             "slice has dispatchable read/write/instantiate actions (SPEC §1.0)"
  end

  test "persistence/0 is {:snapshot, :on_change} — config is durable" do
    assert AgentTemplate.persistence() == {:snapshot, :on_change},
           "AgentTemplate slice must survive phx restart; orchestrator's " <>
             "list_templates depends on persisted templates being there"
  end

  test "Ezagent.Kind behaviour callbacks all implemented" do
    # Spot-check by spawning a Kind.Server and asserting it accepts the
    # AgentTemplate as the kind module argument shape.
    callbacks_ok =
      [:type_name, :behaviors, :persistence]
      |> Enum.all?(fn cb -> function_exported?(AgentTemplate, cb, 0) end)

    assert callbacks_ok,
           "AgentTemplate must implement all three @impl Ezagent.Kind callbacks: " <>
             "type_name/0, behaviors/0, persistence/0"
  end

  describe "to_template_data/2 (Phase 7 completion PR-1, SPEC §1.5 (b))" do
    @instance_uri URI.new!("entity://agent/team-alpha/cc_worker-1")

    test "round-trips a cc-flavored content map to the cc.agent data shape" do
      content = %{
        name: "worker",
        description: "a worker",
        flavor: "cc",
        working_directory: "/tmp/proj"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @instance_uri)
      assert data["class"] == "cc.agent"
      assert data["agent_uri"] == "entity://agent/team-alpha/cc_worker-1"
      assert data["cwd"] == "/tmp/proj"
      # The four optional keys are absent when the content sets none —
      # so the legacy 3-key cc.agent form still validates.
      refute Map.has_key?(data, "operator_settings_path")
      refute Map.has_key?(data, "claude_config_dir")
    end

    test "threads the four optional sandbox keys when present" do
      content = %{
        name: "worker",
        flavor: "cc",
        working_directory: "/tmp/proj",
        settings_path: "/sandbox/settings.json",
        mcp_config_path: "/sandbox/mcp.json",
        claude_config_dir: "/sandbox/.claude",
        api_key_helper: "/sandbox/key.sh"
      }

      assert {:ok, data} = AgentTemplate.to_template_data(content, @instance_uri)
      assert data["operator_settings_path"] == "/sandbox/settings.json"
      assert data["operator_mcp_config_path"] == "/sandbox/mcp.json"
      assert data["claude_config_dir"] == "/sandbox/.claude"
      assert data["api_key_helper"] == "/sandbox/key.sh"
    end

    test "errors when working_directory is missing" do
      content = %{name: "w", flavor: "cc"}
      assert {:error, :missing_working_directory} =
               AgentTemplate.to_template_data(content, @instance_uri)
    end

    test "errors when flavor is missing" do
      content = %{name: "w", working_directory: "/tmp"}
      assert {:error, :missing_flavor} =
               AgentTemplate.to_template_data(content, @instance_uri)
    end

    test "the data map is a string-keyed map the cc Template Class accepts" do
      content = %{name: "w", flavor: "cc", working_directory: "/tmp"}
      {:ok, data} = AgentTemplate.to_template_data(content, @instance_uri)

      assert :ok = Ezagent.PluginCc.Template.CcAgent.validate(data)
    end
  end
end
