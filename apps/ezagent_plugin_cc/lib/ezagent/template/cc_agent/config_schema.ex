defmodule Ezagent.PluginCc.Template.CcAgent.ConfigSchema do
  @moduledoc false

  @doc false
  def fields do
    [
      %{key: "model", type: :string, label: "Model"},
      %{
        key: "effort",
        type: :enum,
        label: "Effort",
        options:
          Application.get_env(:ezagent_plugin_cc, :effort_options, [
            "default",
            "low",
            "medium",
            "high"
          ])
      },
      %{
        key: "permission_mode",
        type: :enum,
        label: "Permission mode",
        options:
          Application.get_env(:ezagent_plugin_cc, :permission_mode_options, [
            "default",
            "acceptEdits",
            "bypassPermissions",
            "plan"
          ]),
        default: "default"
      },
      %{key: "tools", type: :list, label: "Tools"}
    ]
  end
end
