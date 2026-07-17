defmodule Ezagent.PluginCc.Template.CcAgent.Instantiate do
  @moduledoc false

  @doc false
  def instantiate(_name, %{"agent_uri" => uri} = template, workspace, launch_context: context) do
    Ezagent.PluginCc.Template.CcAgent.instantiate_for_flavor(
      Ezagent.PluginCc.Template.CcAgent,
      uri,
      template,
      workspace,
      launch_context: context
    )
  end

  def instantiate(_name, _template, _workspace, _opts), do: {:error, :invalid_launch_options}
end
