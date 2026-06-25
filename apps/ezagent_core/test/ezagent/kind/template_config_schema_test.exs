defmodule Ezagent.Kind.TemplateConfigSchemaTest do
  use ExUnit.Case, async: true

  @moduletag :umbrella_only

  test "Kind.Template exposes optional config_schema/0 callback" do
    assert {:config_schema, 0} in Ezagent.Kind.Template.behaviour_info(:callbacks)
    assert {:config_schema, 0} in Ezagent.Kind.Template.behaviour_info(:optional_callbacks)
  end

  test "cc, codex, and curl template classes expose UI config schema fields" do
    assert [
             %{key: "model", type: :string, label: "Model"},
             %{key: "effort", type: :enum, label: "Effort", options: _},
             %{key: "permission_mode", type: :enum, label: "Permission mode", options: _},
             %{key: "tools", type: :list, label: "Tools"}
           ] = Ezagent.PluginCc.Template.CcAgent.config_schema()

    assert [
             %{key: "model", type: :string, label: "Model"},
             %{key: "approval_policy", type: :enum, label: "Approval policy", options: _},
             %{key: "sandbox", type: :enum, label: "Sandbox", options: _}
           ] = Ezagent.PluginCodex.Template.CodexAgent.config_schema()

    assert [
             %{key: "provider", type: :string, label: "Provider", required: true},
             %{key: "api_url", type: :string, label: "API URL", required: true},
             %{key: "model", type: :string, label: "Model", required: true},
             %{key: "system_prompt", type: :text, label: "System prompt"},
             %{key: "max_history", type: :integer, label: "Max history", default: 20}
           ] = Ezagent.PluginCurlAgent.Template.config_schema()
  end
end
