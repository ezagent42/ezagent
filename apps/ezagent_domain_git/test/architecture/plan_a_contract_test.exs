defmodule EzagentDomainGit.Architecture.PlanAContractTest do
  use ExUnit.Case, async: true

  @structs %{
    Ezagent.DomainGit.RepositoryRef => [
      :repository_uri,
      :provider_adapter,
      :provider_host,
      :external_id,
      :owner_path,
      :base_ref,
      :visibility
    ],
    Ezagent.DomainGit.FileChange => [:path, :operation, :content],
    Ezagent.DomainGit.ChangeRequest => [
      :external_id,
      :url,
      :head_ref,
      :head_sha,
      :base_ref,
      :state
    ],
    Ezagent.DomainGit.OperationContext => [
      :task_access_uri,
      :caller_uri,
      :grantee_uri,
      :idempotency_key
    ],
    Ezagent.DomainGit.CreateChangeRequest => [
      :title,
      :body,
      :head_ref,
      :expected_base_sha,
      :commit_date
    ],
    Ezagent.DomainGit.ChangeRequestId => [:external_id],
    Ezagent.DomainGit.CommitSha => [:value],
    Ezagent.DomainGit.Check => [:external_id, :name, :status, :conclusion, :url],
    Ezagent.DomainGit.Review => [:external_id, :author_label, :state, :submitted_at],
    Ezagent.DomainGit.ChangeLimits => [:max_files, :max_file_bytes, :max_total_bytes]
  }

  test "frozen value namespaces expose exact closed structs and constructors" do
    for {module, fields} <- @structs do
      assert Code.ensure_loaded?(module)

      assert Map.keys(module.__struct__()) |> List.delete(:__struct__) |> Enum.sort() ==
               Enum.sort(fields)

      assert function_exported?(module, :new, 1)
    end

    assert Code.ensure_loaded?(Ezagent.DomainGit.ValidationError)
    assert Code.ensure_loaded?(Ezagent.DomainGit.Error)
    refute :base_ref in Map.keys(Ezagent.DomainGit.CreateChangeRequest.__struct__())
    refute :author in Map.keys(Ezagent.DomainGit.Review.__struct__())
  end

  test "value sources exclude credential, client, payload, local-path, cap, and file-kind axes" do
    value_dir = Path.expand("../../lib/ezagent/domain_git", __DIR__)

    forbidden =
      ~r/\b(token|secret|credential|req|client|checkout_path|local_path|provider_payload|provider_request|provider_response|environment|callback|cap|kind|mode|rename|delete)\s*:/i

    for file <- Path.wildcard(Path.join(value_dir, "*.ex")) do
      refute File.read!(file) =~ forbidden, "forbidden field-like axis in #{file}"
    end
  end

  test "provider error typespec is the exact frozen union and extra members are detected" do
    source = File.read!(Path.expand("../../lib/ezagent/domain_git/error.ex", __DIR__))
    {:ok, ast} = Code.string_to_quoted(source)
    actual = ast |> type_rhs!(:t) |> union_strings()

    expected =
      quote do
        :provider_account_not_connected
        | :credential_backend_unavailable
        | :repository_not_found
        | :repository_read_denied
        | :repository_write_denied
        | :private_checkout_not_supported
        | :base_ref_not_found
        | :base_sha_mismatch
        | :invalid_ref
        | :invalid_file_change
        | :change_limit_exceeded
        | :change_request_conflict
        | :checks_unavailable
        | :provider_unavailable
        | :authentication_rejected
        | :installation_scope_mismatch
        | :head_ref_conflict
        | :provider_rate_limited
        | {:provider_request_failed, operation :: atom(), status :: pos_integer()}
      end
      |> union_strings()

    assert actual == expected
    refute union_strings(quote(do: :allowed | :extra)) == [":allowed"]
  end

  test "adapter exposes only the frozen callbacks and action vocabulary" do
    assert Code.ensure_loaded?(Ezagent.DomainGit.Adapter)

    assert Enum.sort(Ezagent.DomainGit.Adapter.behaviour_info(:callbacks)) ==
             Enum.sort(
               resolve_repository: 2,
               create_change_request: 4,
               read_change_request: 3,
               list_checks: 3,
               list_reviews: 3
             )

    source = File.read!(Path.expand("../../lib/ezagent/domain_git/adapter.ex", __DIR__))
    {:ok, ast} = Code.string_to_quoted(source)

    expected_actions =
      quote do
        :resolve_repository
        | :create_change_request
        | :read_change_request
        | :list_checks
        | :list_reviews
      end
      |> union_strings()

    assert ast |> type_rhs!(:action) |> union_strings() == expected_actions

    refute source =~ ~r/\b(merge|clone|fetch|push|ssh|checkout|credential)\b/i
  end

  test "adapter callback source has exact typed arguments and closed results" do
    source = File.read!(Path.expand("../../lib/ezagent/domain_git/adapter.ex", __DIR__))

    expected = [
      {"resolve_repository", ["OperationContext.t()", "RepositoryRef.t()"], "RepositoryRef.t()"},
      {"create_change_request",
       [
         "OperationContext.t()",
         "RepositoryRef.t()",
         "[FileChange.t()]",
         "CreateChangeRequest.t()"
       ], "ChangeRequest.t()"},
      {"read_change_request",
       ["OperationContext.t()", "RepositoryRef.t()", "ChangeRequestId.t()"], "ChangeRequest.t()"},
      {"list_checks", ["OperationContext.t()", "RepositoryRef.t()", "CommitSha.t()"],
       "[Check.t()]"},
      {"list_reviews", ["OperationContext.t()", "RepositoryRef.t()", "ChangeRequestId.t()"],
       "[Review.t()]"}
    ]

    normalized = String.replace(source, ~r/\s+/, "")

    for {name, arguments, success} <- expected do
      signature =
        "@callback#{name}(#{Enum.join(arguments, ",")})::{:ok,#{success}}|{:error,Error.t()}"

      assert normalized =~ String.replace(signature, ~r/\s+/, "")
    end

    refute source =~
             ~r/\b(map\(\)|token|secret|credential|Req|client|checkout|local_path|Cap|provider_payload)\b/
  end

  defp type_rhs!(ast, name) do
    {_ast, rhs} =
      Macro.prewalk(ast, nil, fn
        {:@, _, [{:type, _, [{:"::", _, [{^name, _, _}, rhs]}]}]} = node, nil -> {node, rhs}
        node, found -> {node, found}
      end)

    rhs || flunk("missing @type #{name}")
  end

  defp union_strings(ast), do: ast |> union_members() |> Enum.map(&Macro.to_string/1)
  defp union_members({:|, _, [left, right]}), do: union_members(left) ++ union_members(right)
  defp union_members(member), do: [member]
end
