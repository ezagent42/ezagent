defmodule EzagentPluginCr.Application do
  @moduledoc "OTP Application for the CR plugin — change request full-publish engine."
  use Application
  use Ezagent.Plugin

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: EzagentPluginCr.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "cr",
      name: "CR",
      description: "Change request full-publish engine — lint, snapshot, publish, rollback.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors, do: []
end
