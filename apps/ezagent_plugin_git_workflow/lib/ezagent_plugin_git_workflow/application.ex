defmodule EzagentPluginGitWorkflow.Application do
  @moduledoc """
  Git Workflow plugin — E2-A dormant declarative contract only.

  Satisfies the non-bypassable :ezagent_plugin_check compiler gate
  (PluginAppsWireContractGateTest). Declares a minimal `plugin_info/0`,
  zero surfaces, and an empty Supervisor. Does NOT call
  Plugin boot is forbidden — E2-A must NOT become a callable entry point.

  Persists durable workflow intents and performs PostgreSQL CAS state
  transitions. No workspace/worker/policy/provider side effects.
  Authorization ingress is deferred to E2-B.
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "git-workflow",
      name: "Git Workflow",
      description: "Durable workflow intent + PostgreSQL CAS for Git provider operations (E2-A dormant).",
      version: "0.1.0"
    }
  end

  # ── Zero surface — E2-A is intentionally dormant ────────────────
  # No behaviors/0, roles/0, children/0, kinds/0, config_surface/0.
  # No ActionSet, route, CLI, agent tool, flavor, resource type,
  # adapter, or CapBAC declaration.
  # E2-A must not call Plugin.boot — no runtime plugin surfaces.
end
