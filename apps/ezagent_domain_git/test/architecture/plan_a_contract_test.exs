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
    Ezagent.DomainGit.CreateChangeRequest => [:title, :body, :head_ref, :expected_base_sha],
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

  test "provider error source contains the exact frozen union and validation stays separate" do
    source = File.read!(Path.expand("../../lib/ezagent/domain_git/error.ex", __DIR__))

    atom_members = [
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
      :authentication_rejected
    ]

    for member <- atom_members do
      assert source =~ ":#{member}"
    end

    assert source =~ "{:provider_request_failed, operation :: atom(), status :: pos_integer()}"
    refute source =~ ":invalid_attributes"
    refute source =~ ":unknown_fields"
    assert length(atom_members) == 15
  end
end
