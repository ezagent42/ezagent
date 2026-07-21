defmodule EzagentPluginGithub.GitHubAdapterTest do
  use ExUnit.Case, async: false

  @stub_name :github_adapter_test

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

  alias EzagentPluginGithub.GitHubAdapter

  setup do
    Application.put_env(:ezagent_plugin_github, :adapter_req_opts, plug: {Req.Test, @stub_name})

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :adapter_req_opts)
    end)

    :ok
  end

  # ── resolve_repository ──────────────────────────────────────────────────

  test "resolve_repository returns RepositoryRef on 200" do
    Req.Test.stub(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "full_name" => "owner/repo",
        "default_branch" => "main",
        "private" => false
      })
    end)

    assert {:ok, %RepositoryRef{external_id: "owner/repo", base_ref: "main"}} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  test "resolve_repository maps 404 to repository_not_found" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :repository_not_found} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  test "resolve_repository maps 401 to authentication_rejected" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"message": "Bad credentials"}))
    end)

    assert {:error, :authentication_rejected} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  test "resolve_repository maps 403 to repository_read_denied" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :repository_read_denied} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  # ── create_change_request ───────────────────────────────────────────────

  test "create_change_request returns ChangeRequest on 201" do
    sha = String.duplicate("a", 40)

    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => sha},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request maps 422 to change_request_conflict" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 422, ~s({"message": "Validation error"}))
    end)

    assert {:error, :change_request_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request maps 403 to repository_write_denied" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :repository_write_denied} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  # ── read_change_request ─────────────────────────────────────────────────

  test "read_change_request returns ChangeRequest on 200 with merged state" do
    sha = String.duplicate("a", 40)

    Req.Test.stub(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "closed",
        "head" => %{"ref" => "feature-branch", "sha" => sha},
        "base" => %{"ref" => "main"},
        "merged" => true
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :merged}} =
             GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
  end

  test "read_change_request returns ChangeRequest on 200 with closed state" do
    sha = String.duplicate("a", 40)

    Req.Test.stub(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "closed",
        "head" => %{"ref" => "feature-branch", "sha" => sha},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :closed}} =
             GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
  end

  test "read_change_request maps 404 to repository_not_found" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :repository_not_found} =
             GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
  end

  # ── list_checks ─────────────────────────────────────────────────────────

  test "list_checks returns [Check] on 200" do
    Req.Test.stub(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "total_count" => 1,
        "check_runs" => [
          %{
            "id" => 789,
            "name" => "ci/test",
            "status" => "completed",
            "conclusion" => "success",
            "details_url" => "https://github.com/owner/repo/actions/runs/1"
          }
        ]
      })
    end)

    assert {:ok,
            [
              %Check{
                external_id: "789",
                name: "ci/test",
                status: :completed,
                conclusion: :succeeded
              }
            ]} =
             GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  test "list_checks returns empty list when no check runs" do
    Req.Test.stub(@stub_name, fn conn ->
      Req.Test.json(conn, %{"total_count" => 0, "check_runs" => []})
    end)

    assert {:ok, []} = GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  test "list_checks maps 403 to checks_unavailable" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :checks_unavailable} =
             GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  # ── list_reviews ────────────────────────────────────────────────────────

  test "list_reviews returns [Review] on 200" do
    Req.Test.stub(@stub_name, fn conn ->
      Req.Test.json(conn, [
        %{
          "id" => 456,
          "user" => %{"login" => "octocat"},
          "state" => "approved",
          "submitted_at" => "2024-01-15T10:30:00Z"
        }
      ])
    end)

    assert {:ok, [%Review{external_id: "456", author_label: "octocat", state: :approved}]} =
             GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  test "list_reviews returns empty list when no reviews" do
    Req.Test.stub(@stub_name, fn conn ->
      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  test "list_reviews maps 404 to repository_not_found" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :repository_not_found} =
             GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp ctx do
    workspace = "test-ws"
    hash = Base.encode16(:crypto.hash(:sha256, "github-adapter"), case: :lower)

    {:ok, ctx} =
      OperationContext.new(%{
        task_access_uri: Ezagent.URI.worker(workspace, "gta_#{hash}"),
        caller_uri: Ezagent.URI.entity(workspace, "agent", "caller"),
        grantee_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
        idempotency_key: "adapter-test-idem-1"
      })

    ctx
  end

  defp repo do
    {:ok, repo} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "owner-repo"),
        provider_adapter: EzagentPluginGithub.GitHubAdapter,
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :public
      })

    repo
  end

  defp file_change do
    {:ok, fc} =
      FileChange.new(%{path: "README.md", operation: :upsert, content: "updated content"})

    fc
  end

  defp create_request do
    {:ok, sha} = CommitSha.new(%{value: String.duplicate("a", 40)})

    {:ok, cr} =
      CreateChangeRequest.new(%{
        title: "Test PR",
        body: "PR body text",
        head_ref: "feature-branch",
        expected_base_sha: sha
      })

    cr
  end

  defp change_request_id do
    {:ok, id} = ChangeRequestId.new(%{external_id: "42"})
    id
  end

  defp commit_sha do
    {:ok, sha} = CommitSha.new(%{value: String.duplicate("a", 40)})
    sha
  end
end
