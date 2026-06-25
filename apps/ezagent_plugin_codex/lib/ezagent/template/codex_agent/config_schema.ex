defmodule Ezagent.PluginCodex.Template.CodexAgent.ConfigSchema do
  @moduledoc false

  @doc false
  def fields do
    [
      %{key: "model", type: :string, label: "Model"},
      %{
        key: "approval_policy",
        type: :enum,
        label: "Approval policy",
        options:
          Application.get_env(:ezagent_plugin_codex, :approval_policy_options, [
            "never",
            "on-request",
            "untrusted"
          ])
      },
      %{
        key: "sandbox",
        type: :enum,
        label: "Sandbox",
        options:
          Application.get_env(:ezagent_plugin_codex, :sandbox_options, [
            "read-only",
            "workspace-write",
            "danger-full-access"
          ])
      }
    ]
  end
end
