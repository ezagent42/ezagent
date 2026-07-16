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
    assert GitTaskAccess.behaviors() == [Ezagent.ActionSet.GitTaskAccess]
  end

  test "builds action targets only from a validated policy and its allowed action subset" do
    assert {:ok, policy} =
             policy_attrs(%{allowed_actions: [:resolve_repository]}) |> GitTaskAccess.new()

    assert GitTaskAccess.uri_from_args(policy) ==
             Ezagent.URI.resource("acme", "git-task-access", "access-17")

    assert {:ok, target} = GitTaskAccess.action_uri(policy, :resolve_repository)

    assert target ==
             Ezagent.URI.with_action(
               Ezagent.URI.resource("acme", "git-task-access", "access-17"),
               :git_task_access,
               :resolve_repository
             )

    assert {:error, :action_not_allowed} =
             GitTaskAccess.action_uri(policy, :create_change_request)

    assert {:error, :action_not_allowed} =
             GitTaskAccess.validate_invocation(policy, %{action: :create_change_request})
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

    assert :ok = GitTaskAccess.validate_invocation(policy, %{action: :resolve_repository})

    assert :ok =
             GitTaskAccess.validate_invocation(policy, %{
               action: :create_change_request,
               head_ref: "task/task-17-g3"
             })

    assert {:error, :head_ref_not_allowed} =
             GitTaskAccess.validate_invocation(policy, %{
               action: :create_change_request,
               head_ref: "other"
             })

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

  test "the live Resource slice retains policy and makes repeated spawn policy observable" do
    assert {:ok, policy} = GitTaskAccess.new(policy_attrs())
    uri = GitTaskAccess.uri_from_args(policy)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(GitTaskAccess, %{uri: uri, policy: policy})

    assert {:ok, %{policy: ^policy}} = Ezagent.Kind.get_slice(uri, :git_task_access)

    assert {:error, {:already_registered, "resource://acme/git-task-access/access-17"}} =
             Ezagent.Kind.spawn(GitTaskAccess, %{uri: uri, policy: policy})

    assert :ok = GitTaskAccess.initialization_result(uri, policy)

    assert {:ok, conflicting} =
             GitTaskAccess.new(policy_attrs(%{allowed_head_ref: "other"}))

    assert {:error, :conflicting_initialization} =
             GitTaskAccess.initialization_result(uri, conflicting)
  end

  test "Lifecycle creation rejects a spawn URI that does not match the policy" do
    assert {:ok, policy} = GitTaskAccess.new(policy_attrs())
    wrong_uri = Ezagent.URI.resource("acme", "git-task-access", "other")

    assert {:error, _reason} =
             Ezagent.Kind.spawn(GitTaskAccess, %{uri: wrong_uri, policy: policy})
  end

  test "public policy consumers revalidate forged policy and nested repository structs" do
    assert {:ok, policy} = GitTaskAccess.new(policy_attrs())

    forged_policy = %{policy | provider_adapter: :redirected_provider}
    assert {:error, {:invalid_field, :provider_adapter}} = GitTaskAccess.revalidate(forged_policy)

    assert {:error, {:invalid_field, :provider_adapter}} =
             GitTaskAccess.action_uri(forged_policy, :resolve_repository)

    forged_repository = %{
      policy.repository
      | repository_uri:
          policy.repository.repository_uri |> Ezagent.URI.with_action(:git, :redirect)
    }

    forged_nested = %{policy | repository: forged_repository}

    assert {:error, {:invalid_field, :repository}} = GitTaskAccess.revalidate(forged_nested)

    malformed_repository = %{policy.repository | base_ref: "refs/heads/main"}

    assert {:error, {:invalid_field, :repository}} =
             GitTaskAccess.revalidate(%{policy | repository: malformed_repository})
  end

  test "ambiguous atom and string head refs are rejected deterministically" do
    assert {:ok, policy} = GitTaskAccess.new(policy_attrs())

    assert {:error, :ambiguous_head_ref} =
             GitTaskAccess.validate_invocation(policy, %{
               "head_ref" => "other",
               action: :create_change_request,
               head_ref: policy.allowed_head_ref
             })

    assert {:error, :ambiguous_head_ref} =
             GitTaskAccess.validate_invocation(policy, %{
               "head_ref" => policy.allowed_head_ref,
               action: :create_change_request,
               head_ref: policy.allowed_head_ref
             })
  end
end
