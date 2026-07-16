defmodule Ezagent.Entity.GitTaskAccessTest do
  use ExUnit.Case, async: true

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.Entity.GitTaskAccess

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]

  defp policy_attrs(overrides \\ %{}) do
    workspace_uri = Ezagent.URI.workspace("acme")

    repository_attrs = %{
      repository_uri: Ezagent.URI.resource("acme", "git-repository", "repo-42"),
      provider_adapter: :fake_git,
      provider_host: "git.example",
      external_id: "42",
      owner_path: "acme/widgets",
      base_ref: "main",
      visibility: :private
    }

    {:ok, repository} = RepositoryRef.new(repository_attrs)

    Map.merge(
      %{
        id: "access-17",
        task_id: "task-17",
        generation: 3,
        workspace_uri: workspace_uri,
        credential_owner_uri: Ezagent.URI.user("acme", "owner"),
        grantee_uri: Ezagent.URI.agent("acme", "codex-17"),
        repository: repository,
        provider_adapter: :fake_git,
        allowed_head_ref: "task/task-17-g3",
        allowed_actions: @actions,
        idempotency_inputs: %{task_id: "task-17", generation: 3}
      },
      overrides
    )
  end

  test "declares a cold ephemeral Resource Kind" do
    assert GitTaskAccess.__pattern__() == :resource
    assert GitTaskAccess.type_name() == :git_task_access
    assert GitTaskAccess.persistence() == :ephemeral
    assert GitTaskAccess.behaviors() == []
  end

  test "builds only the exact canonical task-access URI and action target" do
    attrs = policy_attrs()

    assert GitTaskAccess.uri_from_args(attrs) ==
             Ezagent.URI.resource("acme", "git-task-access", "access-17")

    assert GitTaskAccess.action_uri(attrs, :create_change_request) ==
             Ezagent.URI.with_action(
               Ezagent.URI.resource("acme", "git-task-access", "access-17"),
               :git_task_access,
               :create_change_request
             )
  end

  test "freezes the authoritative task, provider, repository, and branch policy" do
    assert {:ok, policy} = GitTaskAccess.new(policy_attrs())
    assert policy.task_id == "task-17"
    assert policy.generation == 3
    assert policy.provider_adapter == :fake_git
    assert policy.repository.provider_adapter == :fake_git
    assert policy.allowed_head_ref == "task/task-17-g3"
    assert policy.allowed_actions == @actions
    assert policy.idempotency_inputs == %{task_id: "task-17", generation: 3}

    assert :ok = GitTaskAccess.validate_invocation(policy, %{})
    assert :ok = GitTaskAccess.validate_invocation(policy, %{head_ref: "task/task-17-g3"})

    assert {:error, :head_ref_not_allowed} =
             GitTaskAccess.validate_invocation(policy, %{head_ref: "other"})

    for field <- [
          :workspace_uri,
          :credential_owner_uri,
          :grantee_uri,
          :repository,
          :provider_adapter,
          :allowed_head_ref,
          :allowed_actions,
          :idempotency_inputs,
          :operation_context
        ] do
      assert {:error, {:forbidden_invocation_field, ^field}} =
               GitTaskAccess.validate_invocation(policy, %{field => :attacker_controlled})
    end
  end

  test "rejects malformed ids, malformed principals, and every cross-workspace binding" do
    for id <- ["", "a/b", "../escape", :not_a_binary] do
      assert {:error, {:invalid_field, :id}} = GitTaskAccess.new(policy_attrs(%{id: id}))
    end

    for {field, uri} <- [
          {:credential_owner_uri, Ezagent.URI.user("other", "owner")},
          {:grantee_uri, Ezagent.URI.agent("other", "codex-17")}
        ] do
      assert {:error, {:invalid_field, ^field}} =
               GitTaskAccess.new(policy_attrs(%{field => uri}))
    end

    other_repository_attrs =
      policy_attrs().repository
      |> Map.from_struct()
      |> Map.put(:repository_uri, Ezagent.URI.resource("other", "git-repository", "repo-42"))

    {:ok, other_repository} = RepositoryRef.new(other_repository_attrs)

    assert {:error, {:invalid_field, :repository}} =
             GitTaskAccess.new(policy_attrs(%{repository: other_repository}))

    assert {:error, {:invalid_field, :provider_adapter}} =
             GitTaskAccess.new(policy_attrs(%{provider_adapter: :redirected_provider}))
  end

  test "same-policy initialization is idempotent and conflicting initialization is rejected" do
    attrs = policy_attrs()
    assert {:ok, policy} = GitTaskAccess.initialize(nil, attrs)
    assert {:ok, ^policy} = GitTaskAccess.initialize(policy, attrs)

    assert {:error, :conflicting_initialization} =
             GitTaskAccess.initialize(policy, %{attrs | allowed_head_ref: "other"})
  end
end
