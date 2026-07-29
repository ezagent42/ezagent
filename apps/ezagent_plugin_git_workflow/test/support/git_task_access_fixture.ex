defmodule EzagentPluginGitWorkflow.GitTaskAccessFixture do
  @moduledoc """
  Builds a valid `Ezagent.Entity.GitTaskAccess` policy and its derived
  coordinates for this plugin's tests.

  Deliberately capability-free: `Ezagent.DomainGit.TestSupport.GitCapFixture`
  mints caps, and no test in Slice P4a has any business holding one. The policy
  shape here is the post-#1588 contract — `task_uri:` (a URI, never `task_id:`)
  and `idempotency_inputs: %{task_uri: ..., generation: ...}` — copied from
  `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs`.

  Slice P4b adds `binding/1` and `run/1`: the two DURABLE records
  `PolicyDerivation.derive/2` reads. They live here rather than in a separate
  module because P4b's whole claim is that the policy above is a function of
  exactly those two rows — keeping the three builders together makes a drift
  between them impossible to miss.

  Note the shape difference from `authorization_test.exs`'s binding fixture:
  `task_receiver_uri` here is an **agent** principal. `GitTaskAccess` requires
  the grantee to be a bare agent principal in the policy's workspace, so a
  binding whose receiver is (say) a `kanban-task` resource derives no policy at
  all — a denial, exercised explicitly in `policy_derivation_test.exs`.
  """

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @workspace "git-p4b"
  @binding_id "bnd_p4b"
  @external_task_id "task-p4b-1"

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

  @doc "The default workspace every P4b durable-record fixture lives in."
  def workspace, do: @workspace

  @doc """
  A validated `TaskBinding` whose receiver is an agent principal.

  `overrides` is a map merged over the defaults; `:workspace` is consumed to
  rebuild the URIs rather than merged as a field.
  """
  def binding(overrides \\ %{}) do
    {:ok, binding} = TaskBinding.new(binding_attrs(overrides))
    binding
  end

  @doc "The attribute map behind `binding/1` — for tests that need an INVALID binding."
  def binding_attrs(overrides \\ %{}) do
    workspace = Map.get(overrides, :workspace, @workspace)

    %{
      id: @binding_id,
      generation: 1,
      workspace_uri: Ezagent.URI.workspace(workspace),
      task_receiver_uri: Ezagent.URI.agent(workspace, "task-worker"),
      credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
      repository_uri: Ezagent.URI.resource(workspace, "git-repository", "widgets"),
      provider_adapter: :github,
      provider_host: "git.example.test",
      external_id: "repo-1",
      owner_path: "acme/widgets",
      base_ref: "main",
      visibility: :private,
      allowed_head_namespace: "task/p4b/",
      enabled: true
    }
    |> Map.merge(Map.delete(overrides, :workspace))
  end

  @doc """
  A validated `WorkflowRun` whose id is server-generated exactly the way
  `Store.accept/1` generates it (`WorkflowRun.generate_id/3`), so
  `DeterministicRef.derive/2` accepts it.
  """
  def run(overrides \\ %{}) do
    {:ok, run} = WorkflowRun.new(run_attrs(overrides))
    run
  end

  @doc "The attribute map behind `run/1`."
  def run_attrs(overrides \\ %{}) do
    workspace = Map.get(overrides, :workspace, @workspace)
    binding_id = Map.get(overrides, :binding_id, @binding_id)
    generation = Map.get(overrides, :binding_generation, 1)
    external_task_id = Map.get(overrides, :external_task_id, @external_task_id)

    intent = %{
      binding_id: binding_id,
      binding_generation: generation,
      external_task_id: external_task_id,
      source_task_uri: Ezagent.URI.resource(workspace, "task", "task-p4b"),
      source_revision: nil,
      requested_head_ref: nil
    }

    intent
    |> Map.merge(%{
      id: WorkflowRun.generate_id(binding_id, generation, external_task_id),
      workspace_uri: Ezagent.URI.workspace(workspace),
      status: "accepted",
      state_version: 1,
      input_digest: WorkflowRun.compute_digest(intent),
      last_error_code: nil
    })
    |> Map.merge(Map.delete(overrides, :workspace))
  end
end
