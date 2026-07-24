defmodule EzagentPluginGitWorkflow.Application do
  @moduledoc """
  Git Workflow internal app — E2-A permission-neutral surface.

  Persists durable workflow intents and performs PostgreSQL CAS state
  transitions. No workspace/worker/policy/provider side effects.

  This app is intentionally NOT registered as an Ezagent.Plugin — no
  public ActionSet, route, CLI or agent ingress. Authorization ingress
  is deferred to E2-B.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
