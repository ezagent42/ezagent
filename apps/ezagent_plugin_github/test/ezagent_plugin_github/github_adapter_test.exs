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

  alias EzagentPluginGithub.{GitHubAdapter, InstallationPermissions, TestHelpers}

  setup do
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
    Application.put_env(:ezagent_plugin_github, :private_key, TestHelpers.test_private_key_pem())
    Application.put_env(:ezagent_plugin_github, :adapter_req_opts, plug: {Req.Test, @stub_name})

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_plugin_github, :adapter_req_opts)
    end)

    :ok
  end

  defp future_iso(seconds \\ 3600) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp read_json_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  # Mint sequence responder for `profile`, falling back to `repo_response_fn` for
  # any request that isn't the installation-resolve or token-mint call — i.e. the
  # callback's own bounded repository HTTP batch.
  defp stub_with_mint(profile, repo_response_fn) do
    Req.Test.stub(@stub_name, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/owner/repo/installation"} ->
          Req.Test.json(conn, %{"id" => 123})

        {"POST", "/app/installations/123/access_tokens"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "token" => "ghs-test-token",
            "expires_at" => future_iso(),
            "repository_selection" => "selected",
            "repositories" => [%{"full_name" => "owner/repo"}],
            "permissions" => InstallationPermissions.for!(profile)
          })

        _ ->
          repo_response_fn.(conn)
      end
    end)
  end

  # Ordered `Req.Test.expect` pair for one mint sequence, to prepend before a
  # callback's own ordered repository HTTP batch (used for create_change_request,
  # whose multi-step batch already relies on `Req.Test.expect` ordering).
  defp expect_mint(profile) do
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "token" => "ghs-test-token",
        "expires_at" => future_iso(),
        "repository_selection" => "selected",
        "repositories" => [%{"full_name" => "owner/repo"}],
        "permissions" => InstallationPermissions.for!(profile)
      })
    end)
  end

  # ── operation-scoped mint proof (Plan E E1 DoD) ─────────────────────────

  describe "operation-scoped mint — profile selection and mint count" do
    test "each callback requests exactly its own closed permission profile" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/owner/repo/installation"} ->
            Req.Test.json(conn, %{"id" => 123})

          {"POST", "/app/installations/123/access_tokens"} ->
            {body, conn} = read_json_body(conn)
            send(test_pid, {:mint_permissions, body["permissions"]})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "token" => "ghs-test-token",
              "expires_at" => future_iso(),
              "repository_selection" => "selected",
              "repositories" => [%{"full_name" => "owner/repo"}],
              "permissions" => InstallationPermissions.for!(:metadata_read)
            })

          {"GET", "/repos/owner/repo"} ->
            Req.Test.json(conn, %{"full_name" => "owner/repo", "default_branch" => "main"})
        end
      end)

      assert {:ok, %RepositoryRef{}} = GitHubAdapter.resolve_repository(ctx(), repo())
      assert_received {:mint_permissions, permissions}
      assert permissions == InstallationPermissions.for!(:metadata_read)
    end

    test "create_change_request's multi-step reconciliation batch mints exactly once" do
      sha = String.duplicate("a", 40)

      expect_mint(:change_request_write)

      # 1. GET base ref
      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"object" => %{"sha" => sha}})
      end)

      # 2. GET head ref -> absent
      Req.Test.expect(@stub_name, fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
      end)

      # 3. GET base commit -> tree sha
      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
      end)

      # 4. POST blob
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
      end)

      # 5. POST tree
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
      end)

      # 6. POST commit
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
      end)

      # 7. POST create ref (new -- not PATCH)
      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
      end)

      # 8. GET pulls search -> no existing match
      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

      # 9. POST pulls create
      Req.Test.expect(@stub_name, fn conn ->
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

      # 2 mint calls + 9 reconciliation calls, in this exact order -- if the
      # implementation re-minted per HTTP request instead of once per
      # callback, this ordered Req.Test.expect queue would desync and fail.
      assert {:ok, %ChangeRequest{external_id: "42"}} =
               GitHubAdapter.create_change_request(
                 ctx(),
                 repo(),
                 [file_change()],
                 create_request()
               )
    end

    test "two different callbacks each mint independently (no cross-callback reuse)" do
      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "token" => "ghs-resolve-token",
          "expires_at" => future_iso(),
          "repository_selection" => "selected",
          "repositories" => [%{"full_name" => "owner/repo"}],
          "permissions" => InstallationPermissions.for!(:metadata_read)
        })
      end)

      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"full_name" => "owner/repo", "default_branch" => "main"})
      end)

      assert {:ok, %RepositoryRef{}} = GitHubAdapter.resolve_repository(ctx(), repo())

      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "token" => "ghs-read-token",
          "expires_at" => future_iso(),
          "repository_selection" => "selected",
          "repositories" => [%{"full_name" => "owner/repo"}],
          "permissions" => InstallationPermissions.for!(:change_request_read)
        })
      end)

      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{
          "number" => 42,
          "html_url" => "https://github.com/owner/repo/pull/42",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => String.duplicate("a", 40)},
          "base" => %{"ref" => "main"},
          "merged" => false
        })
      end)

      # A second, independently-queued mint pair proves read_change_request did
      # NOT reuse resolve_repository's token — each callback mints its own.
      assert {:ok, %ChangeRequest{external_id: "42"}} =
               GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
    end

    test "a malformed mint response surfaces as installation_scope_mismatch through the adapter, not a generic error" do
      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/owner/repo/installation"} ->
            Req.Test.json(conn, %{"id" => 123})

          {"POST", "/app/installations/123/access_tokens"} ->
            # Wider-than-requested permissions -- GitHubInstallation's strict
            # scope validation must reject this before any repository call.
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "token" => "ghs-test-token",
              "expires_at" => future_iso(),
              "repository_selection" => "selected",
              "repositories" => [%{"full_name" => "owner/repo"}],
              "permissions" => %{"metadata" => "read", "contents" => "write"}
            })
        end
      end)

      assert {:error, :installation_scope_mismatch} =
               GitHubAdapter.resolve_repository(ctx(), repo())
    end
  end

  # ── resolve_repository ──────────────────────────────────────────────────

  test "resolve_repository returns RepositoryRef on 200" do
    stub_with_mint(:metadata_read, fn conn ->
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
    stub_with_mint(:metadata_read, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :repository_not_found} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  test "resolve_repository maps 401 to authentication_rejected" do
    stub_with_mint(:metadata_read, fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"message": "Bad credentials"}))
    end)

    assert {:error, :authentication_rejected} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  test "resolve_repository maps 403 to repository_read_denied" do
    stub_with_mint(:metadata_read, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :repository_read_denied} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  # ── create_change_request ───────────────────────────────────────────────

  test "create_change_request returns ChangeRequest on 201, using the base commit's tree sha and an exact head+base+open PR search" do
    test_pid = self()
    base_commit_sha = String.duplicate("a", 40)
    base_tree_sha = String.duplicate("t", 40)
    expect_mint(:change_request_write)

    # Step 1: GET base ref
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_commit_sha}})
    end)

    # Step 2: GET head ref -> absent
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    # Step 3: GET base commit -> tree sha (proves the base_tree fix: this
    # call must happen, and its tree.sha -- NOT the base ref's commit sha --
    # must be what step 5 sends as base_tree)
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/commits/#{base_commit_sha}"

      Req.Test.json(conn, %{
        "sha" => base_commit_sha,
        "tree" => %{"sha" => base_tree_sha},
        "parents" => []
      })
    end)

    # Step 4: POST blob
    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    # Step 5: POST tree -- capture body
    Req.Test.expect(@stub_name, fn conn ->
      {body, conn} = read_json_body(conn)
      send(test_pid, {:tree_request_body, body})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    # Step 6: POST commit
    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
    end)

    # Step 7: POST create ref
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/refs"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    # Step 8: GET pulls search -- capture query params, return no matches
    Req.Test.expect(@stub_name, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:pr_search_params, conn.query_params})
      Req.Test.json(conn, [])
    end)

    # Step 9: POST pulls create
    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => String.duplicate("c", 40)},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    assert_received {:tree_request_body, tree_body}
    assert tree_body["base_tree"] == base_tree_sha
    refute tree_body["base_tree"] == base_commit_sha

    assert_received {:pr_search_params, params}
    assert params == %{"head" => "owner:feature-branch", "base" => "main", "state" => "open"}
  end

  test "create_change_request returns invalid_file_change when the head ref is absent and there are no file changes" do
    sha = String.duplicate("a", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :invalid_file_change} =
             GitHubAdapter.create_change_request(ctx(), repo(), [], create_request())
  end

  test "create_change_request with empty file_changes reconciles an already-existing safe head ref straight to the PR search" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha,
        "tree" => %{"sha" => "tree_x"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => head_sha},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42"}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [], create_request())
  end

  test "create_change_request returns base_sha_mismatch when SHA doesn't match" do
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => String.duplicate("b", 40)}})
    end)

    assert {:error, :base_sha_mismatch} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request maps 404 on ref to base_ref_not_found" do
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :base_ref_not_found} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request maps 422 to change_request_conflict" do
    sha = String.duplicate("a", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    # Step 9: POST pulls fails with 422
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 422, ~s({"message": "Validation error"}))
    end)

    assert {:error, :change_request_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request maps 403 to repository_write_denied" do
    sha = String.duplicate("a", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    # Step 9: POST pulls fails with 403
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :repository_write_denied} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  # ── create_change_request: ref + PR reconciliation ────────────────────

  test "create_change_request reconciles an existing safely-provenanced head ref without recreating git data" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    # head ref already exists
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    # existing head commit's sole parent is exactly the verified base sha ->
    # safe to reuse
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/commits/#{head_sha}"

      Req.Test.json(conn, %{
        "sha" => head_sha,
        "tree" => %{"sha" => "tree_x"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    # no blob/tree/commit/ref-create calls -- straight to the PR search
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => head_sha},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42"}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request reconciles an existing head ref and an existing open PR with zero write calls" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha,
        "tree" => %{"sha" => "tree_x"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    # exactly one open PR already matches head+base -- reconcile, do not create
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, [
        %{
          "number" => 42,
          "html_url" => "https://github.com/owner/repo/pull/42",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => head_sha},
          "base" => %{"ref" => "main"},
          "merged" => false
        }
      ])
    end)

    # No further Req.Test.expect entries are registered: any additional HTTP
    # call (a stray POST to blobs/trees/commits/refs/pulls) exhausts the
    # queue and raises, failing this test.
    assert {:ok, %ChangeRequest{external_id: "42", head_sha: ^head_sha, state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request returns head_ref_conflict when the existing head's parent does not match the expected base" do
    sha = String.duplicate("a", 40)
    other_sha = String.duplicate("z", 40)
    head_sha = String.duplicate("b", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    # existing head's parent is a DIFFERENT commit than our verified base
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha,
        "tree" => %{"sha" => "tree_x"},
        "parents" => [%{"sha" => other_sha}]
      })
    end)

    assert {:error, :head_ref_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request returns head_ref_conflict when the existing head commit has no parents" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => head_sha, "tree" => %{"sha" => "tree_x"}, "parents" => []})
    end)

    assert {:error, :head_ref_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request returns change_request_conflict when the PR search finds more than one open match" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha,
        "tree" => %{"sha" => "tree_x"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, [
        %{
          "number" => 42,
          "html_url" => "https://github.com/owner/repo/pull/42",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => head_sha},
          "base" => %{"ref" => "main"},
          "merged" => false
        },
        %{
          "number" => 43,
          "html_url" => "https://github.com/owner/repo/pull/43",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => head_sha},
          "base" => %{"ref" => "main"},
          "merged" => false
        }
      ])
    end)

    assert {:error, :change_request_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  # ── read_change_request ─────────────────────────────────────────────────

  test "read_change_request returns ChangeRequest on 200 with merged state" do
    sha = String.duplicate("a", 40)

    stub_with_mint(:change_request_read, fn conn ->
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

    stub_with_mint(:change_request_read, fn conn ->
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
    stub_with_mint(:change_request_read, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :repository_not_found} =
             GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
  end

  # ── list_checks ─────────────────────────────────────────────────────────

  test "list_checks returns [Check] on 200" do
    stub_with_mint(:checks_read, fn conn ->
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
    stub_with_mint(:checks_read, fn conn ->
      Req.Test.json(conn, %{"total_count" => 0, "check_runs" => []})
    end)

    assert {:ok, []} = GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  test "list_checks maps 403 to checks_unavailable" do
    stub_with_mint(:checks_read, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :checks_unavailable} =
             GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  # ── list_reviews ────────────────────────────────────────────────────────

  test "list_reviews returns [Review] on 200" do
    stub_with_mint(:change_request_read, fn conn ->
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
    stub_with_mint(:change_request_read, fn conn -> Req.Test.json(conn, []) end)

    assert {:ok, []} = GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  test "list_reviews maps 404 to repository_not_found" do
    stub_with_mint(:change_request_read, fn conn ->
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
