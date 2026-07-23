defmodule EzagentDomainGit.AdapterContractTest do
  use ExUnit.Case, async: true

  alias Ezagent.DomainGit.{
    ChangeRequest,
    ChangeRequestId,
    Check,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef,
    Review
  }

  @adapters [
    {Ezagent.DomainGit.TestSupport.FakeGitAdapterA, "fake-a"},
    {Ezagent.DomainGit.TestSupport.FakeGitAdapterB, "fake-b"}
  ]

  @errors [
    :provider_account_not_connected,
    :credential_backend_unavailable,
    :repository_not_found,
    :repository_read_denied,
    :repository_write_denied,
    :private_checkout_not_supported,
    :base_ref_not_found,
    :base_sha_mismatch,
    :invalid_ref,
    :invalid_file_change,
    :change_limit_exceeded,
    :change_request_conflict,
    :checks_unavailable,
    :provider_unavailable,
    :authentication_rejected,
    {:provider_request_failed, :create_change_request, 503}
  ]

  for {adapter, provider} <- @adapters do
    describe "#{inspect(adapter)} shared contract" do
      setup do
        %{adapter: unquote(adapter), provider: unquote(provider)}
      end

      test "executes all five callbacks with typed values and normalized successes", %{
        adapter: adapter,
        provider: provider
      } do
        fixtures = fixtures(provider)

        repository_result = adapter.resolve_repository(fixtures.context, fixtures.repository)
        assert closed_result?(:resolve_repository, repository_result)
        assert {:ok, %RepositoryRef{external_id: ^provider}} = repository_result

        create_result =
          adapter.create_change_request(
            fixtures.context,
            fixtures.repository,
            [fixtures.file_change],
            fixtures.create_request
          )

        assert closed_result?(:create_change_request, create_result)
        assert {:ok, %ChangeRequest{external_id: change_id}} = create_result

        assert change_id == provider <> "-change"

        read_result =
          adapter.read_change_request(
            fixtures.context,
            fixtures.repository,
            fixtures.change_request_id
          )

        assert closed_result?(:read_change_request, read_result)
        assert {:ok, %ChangeRequest{external_id: ^change_id}} = read_result

        checks_result =
          adapter.list_checks(fixtures.context, fixtures.repository, fixtures.commit_sha)

        assert closed_result?(:list_checks, checks_result)
        assert {:ok, [%Check{external_id: check_id}]} = checks_result
        assert check_id == provider <> "-check"

        reviews_result =
          adapter.list_reviews(
            fixtures.context,
            fixtures.repository,
            fixtures.change_request_id
          )

        assert closed_result?(:list_reviews, reviews_result)
        assert {:ok, [%Review{external_id: review_id}]} = reviews_result
        assert review_id == provider <> "-review"
      end

      test "returns every closed provider error without leaking another shape", %{
        adapter: adapter
      } do
        fixtures = fixtures("errors")

        for error <- @errors do
          context = %{fixtures.context | idempotency_key: error_key(error)}

          repository_result = adapter.resolve_repository(context, fixtures.repository)
          assert closed_result?(:resolve_repository, repository_result)
          assert {:error, ^error} = repository_result

          create_result =
            adapter.create_change_request(
              context,
              fixtures.repository,
              [fixtures.file_change],
              fixtures.create_request
            )

          assert closed_result?(:create_change_request, create_result)
          assert {:error, ^error} = create_result

          read_result =
            adapter.read_change_request(
              context,
              fixtures.repository,
              fixtures.change_request_id
            )

          assert closed_result?(:read_change_request, read_result)
          assert {:error, ^error} = read_result

          checks_result = adapter.list_checks(context, fixtures.repository, fixtures.commit_sha)
          assert closed_result?(:list_checks, checks_result)
          assert {:error, ^error} = checks_result

          reviews_result =
            adapter.list_reviews(context, fixtures.repository, fixtures.change_request_id)

          assert closed_result?(:list_reviews, reviews_result)
          assert {:error, ^error} = reviews_result
        end
      end
    end
  end

  test "shared result validator rejects open or malformed shapes" do
    refute closed_result?(:resolve_repository, {:ok, %{}})
    refute closed_result?(:create_change_request, {:ok, struct(ChangeRequest)})
    refute closed_result?(:list_checks, {:ok, [struct(Check, status: :provider_specific)]})
    refute closed_result?(:list_reviews, {:ok, [struct(Review, state: :pending)]})
    refute closed_result?(:read_change_request, {:error, :unexpected})
    refute closed_result?(:read_change_request, {:error, {:provider_request_failed, "read", 500}})
  end

  defp fixtures(provider) do
    workspace = "adapter-contract"
    sha = String.duplicate("a", 40)

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", provider),
        provider_adapter: provider_adapter(provider),
        provider_host: "git.example.test",
        external_id: provider,
        owner_path: "team/#{provider}",
        base_ref: "main",
        visibility: :private
      })

    {:ok, context} =
      OperationContext.new(%{
        task_access_uri:
          Ezagent.URI.worker(
            workspace,
            "gta_#{Base.encode16(:crypto.hash(:sha256, provider), case: :lower)}"
          ),
        caller_uri: Ezagent.URI.entity(workspace, "agent", "caller"),
        grantee_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
        idempotency_key: "success"
      })

    {:ok, file_change} =
      FileChange.new(%{path: "README.md", operation: :upsert, content: provider})

    {:ok, commit_sha} = CommitSha.new(%{value: sha})

    {:ok, create_request} =
      CreateChangeRequest.new(%{
        title: "Contract #{provider}",
        body: "Adapter contract",
        head_ref: "task/#{provider}",
        expected_base_sha: commit_sha
      })

    {:ok, change_request_id} = ChangeRequestId.new(%{external_id: provider <> "-change"})

    %{
      repository: repository,
      context: context,
      file_change: file_change,
      commit_sha: commit_sha,
      create_request: create_request,
      change_request_id: change_request_id
    }
  end

  defp error_key({:provider_request_failed, operation, status}),
    do: "error:provider_request_failed:#{operation}:#{status}"

  defp error_key(error), do: "error:#{error}"

  defp closed_result?(_operation, {:error, {:provider_request_failed, operation, status}}),
    do: is_atom(operation) and is_integer(status) and status > 0

  defp closed_result?(_operation, {:error, error}), do: error in @errors

  defp closed_result?(:resolve_repository, {:ok, %RepositoryRef{} = repository}),
    do: valid_value?(RepositoryRef, repository)

  defp closed_result?(operation, {:ok, %ChangeRequest{} = change_request})
       when operation in [:create_change_request, :read_change_request],
       do: valid_value?(ChangeRequest, change_request)

  defp closed_result?(:list_checks, {:ok, checks}) when is_list(checks),
    do: Enum.all?(checks, &match?(%Check{}, &1)) and Enum.all?(checks, &valid_value?(Check, &1))

  defp closed_result?(:list_reviews, {:ok, reviews}) when is_list(reviews),
    do:
      Enum.all?(reviews, &match?(%Review{}, &1)) and Enum.all?(reviews, &valid_value?(Review, &1))

  defp closed_result?(_operation, _result), do: false

  defp valid_value?(module, value),
    do: match?({:ok, _validated}, module.new(Map.from_struct(value)))

  defp provider_adapter("fake-a"), do: :fake_a
  defp provider_adapter("fake-b"), do: :fake_b
  defp provider_adapter("errors"), do: :errors
end
