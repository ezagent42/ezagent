defmodule Ezagent.DomainGit.ValueContractTest do
  use ExUnit.Case, async: true

  alias Ezagent.DomainGit.{
    ChangeRequest,
    Check,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef,
    Review
  }

  defp uri(string), do: Ezagent.URI.new!(string)
  defp web(string), do: URI.new!(string)
  defp sha(char \\ "a"), do: String.duplicate(char, 40)

  test "validation precedence rejects untrusted keys without echo or atom conversion" do
    unique = "never_atomize_#{System.unique_integer([:positive])}"
    refute existing_atom?(unique)

    assert RepositoryRef.new(%{unique => "secret"}) == {:error, :invalid_attributes}
    refute existing_atom?(unique)

    assert FileChange.new(%{
             path: "a.txt",
             operation: :upsert,
             content: "ok",
             token: "do-not-echo"
           }) == {:error, :unknown_fields}

    assert FileChange.new(%{path: "a.txt"}) == {:error, {:missing_field, :operation}}

    assert FileChange.new(%{path: "/abs", operation: :upsert, content: "ok"}) ==
             {:error, {:invalid_field, :path}}
  end

  test "repository and operation context enforce canonical URI roles and workspace" do
    attrs = %{
      repository_uri: uri("resource://ws/git-repository/repo"),
      provider_adapter: :fake,
      provider_host: "git.example",
      external_id: "42",
      owner_path: "team/repo",
      base_ref: "main",
      visibility: :public
    }

    assert {:ok, %RepositoryRef{base_ref: "main"}} = RepositoryRef.new(attrs)

    assert {:error, {:invalid_field, :repository_uri}} =
             RepositoryRef.new(%{attrs | repository_uri: uri("resource://ws/uploads/repo")})

    context = %{
      task_access_uri: uri("resource://ws/git-task-access/task"),
      caller_uri: uri("entity://ws/user/alice"),
      grantee_uri: uri("entity://ws/agent/codex"),
      idempotency_key: "attempt-1"
    }

    assert {:ok, %OperationContext{}} = OperationContext.new(context)

    assert {:error, {:invalid_field, :grantee_uri}} =
             OperationContext.new(%{context | grantee_uri: uri("entity://other/agent/codex")})

    assert {:error, {:invalid_field, :caller_uri}} =
             OperationContext.new(%{context | caller_uri: uri("entity://other/user/alice")})

    for field <- [:task_access_uri, :caller_uri, :grantee_uri] do
      assert {:error, {:invalid_field, ^field}} =
               OperationContext.new(%{context | field => :not_a_uri})
    end

    assert {:error, {:invalid_field, :task_access_uri}} =
             OperationContext.new(%{
               context
               | task_access_uri: nil,
                 caller_uri: :also_invalid,
                 grantee_uri: "not a URI"
             })
  end

  test "typed Ezagent URI accessors preserve the former positional acceptance set" do
    candidates = [
      uri("resource://ws/git-repository/repo"),
      uri("resource://ws/uploads/repo"),
      uri("entity://ws/user/alice"),
      %URI{scheme: "resource", host: "", path: "/git-repository/repo"},
      %URI{scheme: "resource", host: "ws", path: "/git-repository/repo/extra"},
      %URI{scheme: "resource", host: "ws", path: "/git-repository/repo", query: "x=1"}
    ]

    for candidate <- candidates,
        {scheme, type} <- [{"resource", "git-repository"}, {"entity", nil}] do
      assert RepositoryRef.ezagent_uri?(candidate, scheme, type) ==
               legacy_ezagent_uri?(candidate, scheme, type),
             "candidate=#{inspect(candidate)} scheme=#{scheme} type=#{inspect(type)}"
    end
  end

  test "provider web URLs are absolute safe HTTP(S), not Ezagent URIs" do
    attrs = %{
      external_id: "1",
      url: web("https://git.example/pr/1"),
      head_ref: "feature/x",
      head_sha: sha("A"),
      base_ref: "main",
      state: :open
    }

    assert {:ok, %ChangeRequest{head_sha: normalized}} = ChangeRequest.new(attrs)
    assert normalized == sha("a")

    assert {:error, {:invalid_field, :url}} =
             ChangeRequest.new(%{attrs | url: web("https://user:pass@git.example/pr/1")})

    check = %{
      external_id: "c",
      name: "CI",
      status: :completed,
      conclusion: :action_required,
      url: nil
    }

    assert {:ok, %Check{url: nil}} = Check.new(check)

    assert {:ok, %Check{conclusion: :other}} =
             Check.new(%{check | conclusion: :other, url: web("http://ci.example/run")})
  end

  test "refs use the exact preserved provider-neutral subset" do
    valid = ["main", "Feature/ABC_1-2.3"]

    invalid = [
      "",
      "refs/heads/main",
      "/main",
      "main/",
      ".main",
      "main.",
      "a//b",
      "a..b",
      "a@{b",
      "a b",
      "a~b",
      "a^b",
      "a:b",
      "a?b",
      "a*b",
      "a[b",
      "a\\b",
      "a/.hidden",
      "a/b.lock",
      String.duplicate("a", 256)
    ]

    for ref <- valid do
      assert {:ok, %CreateChangeRequest{head_ref: ^ref}} =
               CreateChangeRequest.new(%{
                 title: "T",
                 body: "B",
                 head_ref: ref,
                 expected_base_sha: struct!(CommitSha, value: sha())
               })
    end

    for ref <- invalid do
      assert {:error, {:invalid_field, :head_ref}} =
               CreateChangeRequest.new(%{
                 title: "T",
                 body: "B",
                 head_ref: ref,
                 expected_base_sha: struct!(CommitSha, value: sha())
               })
    end
  end

  test "SHA-1 validation is shared, normalized, and rejects SHA-256" do
    assert {:ok, %CommitSha{value: value}} = CommitSha.new(%{value: sha("A")})
    assert value == sha("a")
    assert {:error, {:invalid_field, :value}} = CommitSha.new(%{value: String.duplicate("a", 64)})

    request = %{
      title: "T",
      body: "B",
      head_ref: "feature/x",
      expected_base_sha: struct!(CommitSha, value: sha())
    }

    assert {:ok, %CreateChangeRequest{}} = CreateChangeRequest.new(request)

    for forged <- [struct!(CommitSha, value: "invalid"), struct!(CommitSha, value: sha("A"))] do
      assert {:error, {:invalid_field, :expected_base_sha}} =
               CreateChangeRequest.new(%{request | expected_base_sha: forged})
    end
  end

  test "file changes are UTF-8 upserts with protected repository paths" do
    assert {:ok, %FileChange{content: "hello"}} =
             FileChange.new(%{path: "lib/a.ex", operation: :upsert, content: "hello"})

    for path <- [
          "/etc/passwd",
          "../a",
          "a/../b",
          ".git/config",
          "a/.git/x",
          "a//b",
          "a/",
          "a\\b",
          "safe\0file",
          <<"safe", 255>>
        ] do
      assert {:error, {:invalid_field, :path}} =
               FileChange.new(%{path: path, operation: :upsert, content: "x"})
    end

    assert {:error, {:invalid_field, :content}} =
             FileChange.new(%{path: "a", operation: :upsert, content: <<255>>})

    assert {:error, :unknown_fields} =
             FileChange.new(%{path: "a", operation: :upsert, content: "x", kind: :symlink})

    assert {:error, {:invalid_field, :operation}} =
             FileChange.new(%{path: "a", operation: :delete, content: "x"})
  end

  test "review is a submitted event and check conclusions are closed" do
    assert {:ok, %Review{author_label: "Reviewer"}} =
             Review.new(%{
               external_id: "r1",
               author_label: "Reviewer",
               state: :approved,
               submitted_at: nil
             })

    assert {:error, :unknown_fields} =
             Review.new(%{
               external_id: "r1",
               author_label: "Reviewer",
               author: "identity",
               state: :approved,
               submitted_at: nil
             })

    assert {:error, {:invalid_field, :state}} =
             Review.new(%{
               external_id: "r1",
               author_label: "Reviewer",
               state: :pending,
               submitted_at: nil
             })
  end

  defp existing_atom?(string) do
    String.to_existing_atom(string)
    true
  rescue
    ArgumentError -> false
  end

  defp legacy_ezagent_uri?(
         %URI{scheme: scheme, host: host, path: "/" <> path} = uri,
         scheme,
         type
       )
       when is_binary(host) and host != "" do
    Ezagent.URI.canonical?(uri) and uri.query == nil and uri.fragment == nil and
      legacy_uri_path?(String.split(path, "/"), type)
  end

  defp legacy_ezagent_uri?(_uri, _scheme, _type), do: false
  defp legacy_uri_path?([actual_type, name], nil), do: actual_type != "" and name != ""
  defp legacy_uri_path?([type, name], type), do: name != ""
  defp legacy_uri_path?(_segments, _type), do: false
end
