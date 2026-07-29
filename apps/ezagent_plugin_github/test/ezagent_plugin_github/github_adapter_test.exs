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

      # 3. POST create ref, pointing at the verified base sha (Fix 1: this
      # now happens BEFORE any blob/tree/commit work)
      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
      end)

      # 4. GET base commit -> tree sha
      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
      end)

      # 5. POST blob
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
      end)

      # 6. POST tree
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
      end)

      # 7. POST commit
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
      end)

      # 8. PATCH advance ref onto the new commit, non-force (Fix 1)
      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
      end)

      # 9. GET pulls search -> no existing match
      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

      # 10. POST pulls create
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

      # 2 mint calls + 10 reconciliation calls, in this exact order -- if the
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

    # Step 3: POST create ref, pointing at the verified base commit -- Fix 1:
    # this establishes the durable mutation identity BEFORE any blob/tree/
    # commit work, and is asserted here to prove the sha sent is the base
    # commit, not a not-yet-existing head commit.
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/refs"
      {body, conn} = read_json_body(conn)
      send(test_pid, {:ref_create_body, body})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    # Step 4: GET base commit -> tree sha (proves the base_tree fix: this
    # call must happen, and its tree.sha -- NOT the base ref's commit sha --
    # must be what step 6 sends as base_tree)
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/commits/#{base_commit_sha}"

      Req.Test.json(conn, %{
        "sha" => base_commit_sha,
        "tree" => %{"sha" => base_tree_sha},
        "parents" => []
      })
    end)

    # Step 5: POST blob
    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    # Step 6: POST tree -- capture body
    Req.Test.expect(@stub_name, fn conn ->
      {body, conn} = read_json_body(conn)
      send(test_pid, {:tree_request_body, body})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    # Step 7: POST commit
    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
    end)

    # Step 8: PATCH advance ref onto the new commit -- Fix 1: non-force, and
    # asserted here to prove `force: false` is actually sent.
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/refs/heads/feature-branch"
      {body, conn} = read_json_body(conn)
      send(test_pid, {:ref_advance_body, body})
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    # Step 9: GET pulls search -- capture query params, return no matches
    Req.Test.expect(@stub_name, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:pr_search_params, conn.query_params})
      Req.Test.json(conn, [])
    end)

    # Step 10: POST pulls create
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

    assert_received {:ref_create_body, ref_create_body}
    assert ref_create_body["sha"] == base_commit_sha
    assert ref_create_body["ref"] == "refs/heads/feature-branch"

    assert_received {:tree_request_body, tree_body}
    assert tree_body["base_tree"] == base_tree_sha
    refute tree_body["base_tree"] == base_commit_sha

    assert_received {:ref_advance_body, ref_advance_body}
    assert ref_advance_body["sha"] == "commit_sha_1"
    assert ref_advance_body["force"] == false

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

  test "create_change_request with empty file_changes fetches the base tree and posts an empty tree before reconciling the existing head ref to the PR search" do
    test_pid = self()
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
        "tree" => %{"sha" => "tree_base"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    # Fix 2: even with zero file_changes, branch provenance requires proving
    # the existing head's tree matches what this call's (idempotent, empty)
    # tree creation produces -- fetch the base tree sha, then create the
    # (empty) tree; returning the SAME sha as the existing head's tree
    # proves "no changes" reuse is safe. The path/body assertions below are
    # what makes this test actually prove "fetches the base tree and posts
    # an empty tree" instead of merely tolerating it: the stubs return the
    # same canned JSON regardless of what was requested, so without them a
    # regression that fetched the wrong commit or posted a non-empty tree
    # would still produce the same {:ok, ...} result.
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/commits/#{sha}"
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/trees"
      {body, conn} = read_json_body(conn)
      send(test_pid, {:empty_tree_body, body})
      Req.Test.json(conn, %{"sha" => "tree_base"})
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

    assert_received {:empty_tree_body, tree_body}
    assert tree_body["tree"] == []
    assert tree_body["base_tree"] == "tree_base"
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

  test "create_change_request maps a PR-create 422 to change_request_conflict" do
    sha = String.duplicate("a", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
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
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    # Step 10: POST pulls fails with 422 -- a Git-data-unrelated PR-create
    # validation error, correctly kept as change_request_conflict (Fix 5).
    # The path/method assertion is what proves this 422 is genuinely the PR
    # *create* call and not some other step: `:change_request_conflict` is
    # also the PR-search ">1 match" result (`reconcile_pull_request/3`), so
    # without pinning the request here, a regression that misrouted an
    # unrelated 422 into that same atom could pass unnoticed.
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/repos/owner/repo/pulls"
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
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
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
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    # Step 10: POST pulls fails with 403
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :repository_write_denied} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  # ── create_change_request: ref-create 422 disambiguation ───────────────
  #
  # `create_head_commit/5`'s 422 branch (github_adapter.ex) re-reads the head
  # ref path rather than assuming every 422 from ref *creation* means the
  # same thing. The two tests below cover the two outcomes that re-read can
  # have (design §6.2): the ref now being found (a genuine
  # concurrent-creation race -- reconcile normally, no error) vs. the ref
  # still missing (a real ref-validation failure -- fail closed with
  # `:invalid_ref`, not the confusingly-reused `:repository_not_found`).

  test "create_change_request recovers when ref creation 422s because a concurrent creator already planted the marker ref at base" do
    sha = String.duplicate("a", 40)
    new_commit_sha = String.duplicate("c", 40)
    expect_mint(:change_request_write)

    # Step 1: GET base ref
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    # Step 2: GET head ref -> absent, from THIS call's point of view
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    # Step 3: POST create ref -> 422. Not a validation failure: a concurrent
    # creator (e.g. this exact idempotent operation racing itself elsewhere)
    # planted the identical marker ref between this call's step-2 read and
    # its own create attempt.
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/refs"
      Plug.Conn.resp(conn, 422, ~s({"message": "Reference already exists"}))
    end)

    # Step 4: re-read the head ref -- now finds it, sitting exactly at base
    # (the marker the concurrent creator planted). Not an error at all.
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/ref/heads/feature-branch"
      Req.Test.json(conn, %{"object" => %{"sha" => sha}})
    end)

    # The chain resumes exactly as if this call had created the ref itself.
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
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => new_commit_sha})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => new_commit_sha},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request returns invalid_ref when ref creation 422s and a re-read confirms the ref still does not exist" do
    sha = String.duplicate("a", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    # POST create ref -> 422, NOT a benign existence race: a Git-data
    # validation failure unrelated to the ref already existing.
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/refs"
      Plug.Conn.resp(conn, 422, ~s({"message": "Validation Failed"}))
    end)

    # Re-read confirms the ref genuinely still does not exist -- this was
    # never a race with a concurrent creator, so it must fail closed rather
    # than loop back into ref creation, and it must not leak the
    # confusingly-reused `:repository_not_found` (this repository
    # unquestionably exists -- steps 1-2 above already proved that).
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/ref/heads/feature-branch"
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :invalid_ref} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # `Req.Test.expect` entries that are never fetched are NOT verified at
    # test exit on their own (see `Req.Test.verify!/1` moduledoc) -- so
    # without this, an implementation that returned `{:error, :invalid_ref}`
    # right after the 422 (skipping the re-read this test exists to prove
    # happens) would produce the exact same top-level result above and pass
    # anyway, leaving the re-read `Req.Test.expect` above permanently
    # unconsumed. This asserts the queue was fully drained, i.e. the re-read
    # actually happened.
    Req.Test.verify!(@stub_name)
  end

  # ── create_change_request: ref + PR reconciliation ────────────────────

  test "create_change_request reuses an existing head ref whose tree matches, creating no new commit or ref, but does create a PR since the search found none" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    # head ref already exists
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    # existing head commit's sole parent is exactly the verified base sha ->
    # candidate for reuse, pending the tree check below
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/commits/#{head_sha}"

      Req.Test.json(conn, %{
        "sha" => head_sha,
        "tree" => %{"sha" => "tree_match"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    # Fix 2: parent equality alone is not provenance -- recompute this
    # call's tree from file_changes and compare. Fetch the base tree sha,
    # then (idempotently) create blob + tree; returning the SAME sha as the
    # existing head's tree proves reuse is safe.
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => "tree_match"})
    end)

    # no commit/ref-create/ref-advance calls -- straight to the PR search
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

  test "create_change_request reconciles an existing head ref and an existing open PR after verifying tree provenance, creating no new commit, ref, or PR" do
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
        "tree" => %{"sha" => "tree_match"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    # Fix 2's tree-provenance round trip (idempotent blob/tree creation, no
    # new commit or ref) still runs before the PR search.
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => "tree_match"})
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
    # call (a stray POST to commits/refs/pulls, or a repeated blob/tree
    # call) exhausts the queue and raises, failing this test.
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

  test "create_change_request returns head_ref_conflict when the existing head has the correct parent but a different tree" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    # parent matches the verified base, but this is not enough on its own
    # (Fix 2) -- any unrelated commit built on the same base would also
    # match the parent check.
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha,
        "tree" => %{"sha" => "some_other_tree"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    # This call's own (idempotent) tree creation produces a DIFFERENT tree
    # sha than the existing head's -- branch provenance fails, even though
    # the parent matched.
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => "this_calls_own_tree"})
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
        "tree" => %{"sha" => "tree_match"},
        "parents" => [%{"sha" => sha}]
      })
    end)

    # Fix 2's tree-provenance round trip passes (tree matches), so the
    # reconciliation proceeds to the PR search where it finds a conflict.
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => "tree_match"})
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
        credential_owner_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
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
        expected_base_sha: sha,
        commit_date: ~U[2026-06-15 09:30:00Z]
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
