defmodule EzagentPluginGitWorkflow.Application do
  @moduledoc """
  Git Workflow plugin OTP application.

  Minimal E2 surface: persists durable workflow intents and performs
  PostgreSQL CAS state transitions. No workspace/worker/policy/provider
  side effects.
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args) do
    Ezagent.Plugin.boot(__MODULE__)
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "git-workflow",
      name: "Git Workflow",
      description: "Durable workflow intent + PostgreSQL CAS for Git provider operations.",
      version: "0.1.0"
    }
  end
end
