defmodule Ezagent.PluginCodex.Template.CodexAgent.Instantiate do
  @moduledoc false

  @doc false
  def instantiate(_name, %{"agent_uri" => uri} = template, workspace, launch_context: context) do
    Ezagent.PluginCodex.Template.CodexAgent.instantiate_with_opts(
      uri,
      template,
      workspace,
      launch_context: context
    )
  end

  def instantiate(_name, _template, _workspace, _opts), do: {:error, :invalid_launch_options}
end
