defmodule EzagentPluginGitWorkflow.ExecutionSeam do
  @moduledoc """
  Fail-closed authorization/execution seam — the ONLY internal chokepoint
  the workflow depends on to obtain an authorized task and invoke a
  provider-neutral action against it (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §3.1).

  `authorized_task` must encapsulate only a validated exact `GitTaskAccess`
  policy, task URI, and generation. It must NEVER carry a raw cap, an
  `%Invocation{}`, `ctx.caps`, a GitHub token, or any caller-supplied
  credential (§3.2).

  The production default (`EzagentPluginGitWorkflow.ExecutionSeam.Unavailable`)
  always returns `{:error, :authorization_unavailable}` and performs zero
  workspace/filesystem/provider/Agent side effects. Only test code may
  configure a different implementation, and only via
  `Application.put_env/3` in `config/test.exs` or a test's own setup —
  never via runtime env, a route, an ActionSet, a CLI, or an agent tool
  parameter. `architecture_test.exs` enforces this.
  """

  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @type authorized_task :: term()
  @type action :: atom()
  @type typed_args :: term()
  @type typed_result :: term()

  @callback authorize(WorkflowRun.t(), TaskBinding.t()) ::
              {:ok, authorized_task()}
              | {:error, :authorization_unavailable}
              | {:error, :not_authorized}

  @callback invoke(authorized_task(), action(), typed_args()) ::
              {:ok, typed_result()} | {:error, term()}

  @doc "Resolves the configured seam implementation. Defaults to the fail-closed backend."
  @spec implementation() :: module()
  def implementation do
    Application.get_env(:ezagent_plugin_git_workflow, :execution_seam, __MODULE__.Unavailable)
  end
end
