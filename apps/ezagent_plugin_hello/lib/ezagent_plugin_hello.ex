defmodule EzagentPluginHello do
  @moduledoc """
  Top-level helpers for the hello plugin.

  """

  @doc """
  The hello home workspace name (default `"ezagent"`).
  (`config :ezagent_plugin_hello, :home_workspace, ...`) takes effect without a
  recompile, and so no caller ever passes the workspace as an argument (the
  credential path stays non-caller-redirectable, #185).
  """
  @spec home_workspace() :: String.t()
  def home_workspace do
    Application.get_env(:ezagent_plugin_hello, :home_workspace, "ezagent")
  end
end
