defmodule EzagentPluginGitWorkflow.GitTaskAccessFixture do
  @moduledoc """
  Builds a valid `Ezagent.Entity.GitTaskAccess` policy and its derived
  coordinates for this plugin's tests.

  Deliberately capability-free: `Ezagent.DomainGit.TestSupport.GitCapFixture`
  mints caps, and no test in Slice P4a has any business holding one. The policy
  shape here is the post-#1588 contract — `task_uri:` (a URI, never `task_id:`)
  and `idempotency_inputs: %{task_uri: ..., generation: ...}` — copied from
  `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`.
  """

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.Entity.GitTaskAccess

  @doc """
  Returns `%{policy:, task_access_uri:, task_uri:, generation:}` — exactly the
  four values `AuthorizedTask.new/1` consumes, already mutually consistent.
  """
  def authorized_task_attrs(overrides \\ []) do
    policy = policy(overrides)

    %{
      policy: policy,
      task_access_uri: GitTaskAccess.uri_from_args(policy),
      task_uri: policy.task_uri,
      generation: policy.generation
    }
  end

  @doc "Builds a valid policy. `:workspace`, `:generation` and `:allowed_actions` are overridable."
  def policy(overrides \\ []) do
    overrides =
      Keyword.validate!(overrides,
        workspace: "git-p4a",
        generation: 1,
        allowed_actions: [:resolve_repository, :create_change_request]
      )

    workspace = Keyword.fetch!(overrides, :workspace)
    generation = Keyword.fetch!(overrides, :generation)
    task_uri = Ezagent.URI.resource(workspace, "task", "task-p4a")

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", "widgets"),
        provider_adapter: :github,
        provider_host: "git.example.test",
        external_id: "repo-1",
        owner_path: "acme/widgets",
        base_ref: "main",
        visibility: :private
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: "gta-p4a",
        task_uri: task_uri,
        generation: generation,
        workspace_uri: Ezagent.URI.workspace(workspace),
        credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
        grantee_uri: Ezagent.URI.agent(workspace, "task-worker"),
        repository: repository,
        provider_adapter: :github,
        allowed_head_ref: "task/p4a",
        allowed_actions: Keyword.fetch!(overrides, :allowed_actions),
        idempotency_inputs: %{task_uri: task_uri, generation: generation}
      })

    policy
  end
end
