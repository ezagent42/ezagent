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
            Req.Test.json(conn, %{
              "full_name" => "owner/repo",
              "default_branch" => "main",
              "private" => false
            })
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
        Req.Test.json(conn, %{
          "full_name" => "owner/repo",
          "default_branch" => "main",
          "private" => false
        })
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

  test "resolve_repository reports a private repository as :private" do
    stub_with_mint(:metadata_read, fn conn ->
      Req.Test.json(conn, %{
        "full_name" => "owner/repo",
        "default_branch" => "main",
        "private" => true
      })
    end)

    assert {:ok, %RepositoryRef{visibility: :private}} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  # `visibility` is not a label: `TaskWorkspace.Provisioner` refuses a checkout
  # on `:private` and permits one on `:public`. Reading an ABSENT `private` field
  # for truthiness answered `:public` and handed a private repository the
  # permission its owner never gave.
  test "resolve_repository refuses a body with no private field rather than assuming :public" do
    stub_with_mint(:metadata_read, fn conn ->
      Req.Test.json(conn, %{"full_name" => "owner/repo", "default_branch" => "main"})
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.resolve_repository(ctx(), repo())
  end

  # Falling back to the caller's own request values reports what we ASKED about
  # as though the provider had confirmed it.
  test "resolve_repository refuses a body missing full_name or default_branch" do
    for partial <- [
          %{"default_branch" => "main", "private" => false},
          %{"full_name" => "owner/repo", "private" => false}
        ] do
      stub_with_mint(:metadata_read, fn conn -> Req.Test.json(conn, partial) end)

      assert {:error, :provider_response_unrecognized} =
               GitHubAdapter.resolve_repository(ctx(), repo()),
             "expected refusal for #{inspect(partial)}"
    end
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

  # Asserted as a PAIR with the case below it. `:base_sha_mismatch` is an
  # actionable diagnosis — it tells an operator the base branch moved and the
  # work needs rebasing — and it is only true when two shas were actually
  # COMPARED. Answering it for a body we could not read invents that diagnosis
  # and sends someone to rebase against a base that may not have moved at all.
  test "create_change_request returns base_sha_mismatch when SHA doesn't match" do
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => String.duplicate("b", 40)}})
    end)

    assert {:error, :base_sha_mismatch} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request refuses an unreadable base ref instead of claiming a sha mismatch" do
    for body <- [%{"unexpected" => true}, %{"object" => %{}}, %{"object" => "not-a-map"}] do
      expect_mint(:change_request_write)
      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, body) end)

      assert {:error, :provider_response_unrecognized} =
               GitHubAdapter.create_change_request(
                 ctx(),
                 repo(),
                 [file_change()],
                 create_request()
               ),
             "expected refusal for #{inspect(body)}"
    end
  end

  test "create_change_request maps 404 on ref to base_ref_not_found" do
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :base_ref_not_found} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  # ── create_change_request: a malformed 2xx at each write/reconcile step ──
  #
  # The read path's parse refusals are covered further down. These pin the WRITE
  # and reconciliation steps, which carry their own `{:ok, _unexpected}` clauses.
  # Without them a later refactor could keep the read path classified correctly
  # and quietly collapse these back onto `:provider_unavailable` — which is
  # RETRYABLE, so a provider whose git-data payloads changed shape would be
  # re-asked until the deadline instead of reported to an operator.
  for {step, label} <- [
        {4, "base-commit"},
        {5, "blob"},
        {6, "tree"},
        {7, "commit"},
        {9, "pull-request search"}
      ] do
    test "create_change_request refuses a malformed 2xx from the #{label} step" do
      expect_mint(:change_request_write)
      expect_create_steps_until(unquote(step))

      # A 2xx whose body carries none of the keys this step reads.
      expect_malformed_at(unquote(step))

      assert {:error, :provider_response_unrecognized} =
               GitHubAdapter.create_change_request(
                 ctx(),
                 repo(),
                 [file_change()],
                 create_request()
               )
    end
  end

  @create_steps [
    {"GET", "/repos/owner/repo/git/ref/heads/main"},
    {"GET", "/repos/owner/repo/git/ref/heads/feature-branch"},
    {"POST", "/repos/owner/repo/git/refs"},
    {"GET", "/repos/owner/repo/git/commits/" <> String.duplicate("a", 40)},
    {"POST", "/repos/owner/repo/git/blobs"},
    {"POST", "/repos/owner/repo/git/trees"},
    {"POST", "/repos/owner/repo/git/commits"},
    {"PATCH", "/repos/owner/repo/git/refs/heads/feature-branch"},
    {"GET", "/repos/owner/repo/pulls"}
  ]

  # The successful responses for create_change_request's ordered HTTP batch,
  # steps 1..n-1, so the test above can arm exactly one malformed reply at step n.
  #
  # Every step asserts its own METHOD and PATH before answering. Without that the
  # queue is positional only, and a production change that skips a call shifts
  # every later reply one slot: the test named "malformed tree" would then feed
  # the tree reply to the commit call, the malformed body would land on commit —
  # which refuses with the same atom — and the assertion would pass green while
  # the tree clause was never executed at all.
  defp expect_create_steps_until(step) do
    sha = String.duplicate("a", 40)

    bodies = [
      fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end,
      fn conn -> Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"})) end,
      fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
      end,
      fn conn ->
        Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
      end,
      fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"}) end,
      fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"}) end,
      fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
      end,
      fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
      end
    ]

    bodies
    |> Enum.zip(@create_steps)
    |> Enum.take(step - 1)
    |> Enum.each(fn {body, step_spec} -> expect_step(step_spec, body) end)
  end

  # The step under test asserts its method/path too, so a desync is caught AT the
  # malformed reply rather than silently redirecting it to a different clause.
  defp expect_malformed_at(step) do
    expect_step(Enum.at(@create_steps, step - 1), fn conn ->
      Req.Test.json(conn, %{"unexpected" => true})
    end)
  end

  defp expect_step({method, path}, body) do
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.method == method
      assert conn.request_path == path
      body.(conn)
    end)
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

  # The three `:head_ref_conflict` tests below are the readable half: the
  # provider's answer was understood and it genuinely disagrees with what this
  # run expected. The two here are the unreadable half, and they used to answer
  # `:head_ref_conflict` too — the clause that produced it was literally named
  # `_mismatched_or_unexpected_shape`.
  #
  # That conflation invents a diagnosis. `:head_ref_conflict` tells an operator
  # somebody else moved this branch, which is a specific, checkable claim about
  # the repository. "We could not read the commit body" is a claim about the
  # API, and the two send an operator to different places.
  test "create_change_request refuses an unreadable head commit instead of claiming a conflict" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)

    for body <- [
          %{"unexpected" => true},
          %{"tree" => %{"sha" => "tree_x"}},
          %{"tree" => "not-a-map", "parents" => [%{"sha" => sha}]},
          %{"tree" => %{"sha" => "tree_x"}, "parents" => "not-a-list"}
        ] do
      expect_mint(:change_request_write)

      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"object" => %{"sha" => sha}})
      end)

      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
      end)

      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, body) end)

      assert {:error, :provider_response_unrecognized} =
               GitHubAdapter.create_change_request(
                 ctx(),
                 repo(),
                 [file_change()],
                 create_request()
               ),
             "expected refusal for #{inspect(body)}"
    end
  end

  test "create_change_request refuses an unreadable head ref instead of claiming a conflict" do
    sha = String.duplicate("a", 40)

    for body <- [%{"unexpected" => true}, %{"object" => %{}}, %{"object" => %{"sha" => 12_345}}] do
      expect_mint(:change_request_write)

      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"object" => %{"sha" => sha}})
      end)

      # The head ref exists (200) but its body carries no usable sha.
      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, body) end)

      assert {:error, :provider_response_unrecognized} =
               GitHubAdapter.create_change_request(
                 ctx(),
                 repo(),
                 [file_change()],
                 create_request()
               ),
             "expected refusal for #{inspect(body)}"
    end
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

  # `ChangeRequest.state` has no "unmapped" member either, and `:closed` is a
  # terminal answer the workflow acts on. An unrecognized state is refused.
  test "read_change_request refuses an unknown pull request state rather than guessing" do
    sha = String.duplicate("a", 40)

    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, %{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "archived",
        "head" => %{"ref" => "feature-branch", "sha" => sha},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
  end

  # The adapter callback is typed `{:error, Ezagent.DomainGit.Error.t()}` and that
  # union is frozen by `plan_a_contract_test`. A `ValidationError` tuple leaking
  # out of value construction is off-contract, however malformed the body was.
  test "read_change_request returns a domain error atom, never a validation error tuple" do
    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, %{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:error, reason} =
             GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())

    # Membership, not `is_atom/1`: an invented atom is an atom too, and the
    # frozen typespec test checks the DECLARATION, never a value this adapter
    # actually emits.
    assert reason in domain_git_errors(),
           "expected a member of DomainGit.Error.t(), got: #{inspect(reason)}"
  end

  # A closed pull request whose `merged` discriminator is absent cannot be told
  # apart from a merged one, and `:closed` is not a safe default for that — it
  # erases the merge, which is the single fact a reviewer cares about most.
  test "read_change_request refuses a closed pull request with no merged discriminator" do
    sha = String.duplicate("a", 40)

    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, %{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "closed",
        "head" => %{"ref" => "feature-branch", "sha" => sha},
        "base" => %{"ref" => "main"}
      })
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
  end

  # An OPEN pull request is definitionally not merged, and the pull-request LIST
  # endpoint `reconcile_pull_request/3` reads (pinned to `state: "open"`) does
  # not carry `merged` at all. Requiring it there would fail a read that is
  # perfectly well understood — this pins the asymmetry deliberately.
  test "read_change_request accepts an open pull request with no merged discriminator" do
    sha = String.duplicate("a", 40)

    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, %{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => sha},
        "base" => %{"ref" => "main"}
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
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

  # `waiting` / `requested` / `pending` are the three statuses GitHub documents
  # alongside the three this adapter originally mapped. All three mean "has not
  # started", which `Check` spells `:queued` — a deployment-gated or
  # concurrency-queued run must survive the read, not vanish from it.
  test "list_checks maps every documented not-started status onto :queued" do
    stub_with_mint(:checks_read, fn conn ->
      Req.Test.json(conn, %{
        "total_count" => 3,
        "check_runs" => [
          %{"id" => 1, "name" => "gate/deploy", "status" => "waiting", "conclusion" => nil},
          %{"id" => 2, "name" => "gate/request", "status" => "requested", "conclusion" => nil},
          %{"id" => 3, "name" => "gate/pending", "status" => "pending", "conclusion" => nil}
        ]
      })
    end)

    assert {:ok, checks} = GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
    assert Enum.map(checks, & &1.external_id) == ["1", "2", "3"]
    assert Enum.all?(checks, &(&1.status == :queued and is_nil(&1.conclusion)))
  end

  # An unknown status is refused for the WHOLE read rather than guessed at.
  # `Check.status` has no "unmapped" member to degrade to, so any specific value
  # here is an invention — and `:completed` in particular reads as "this finished".
  #
  # The unknown entry carries a RECOGNIZED conclusion on purpose: a guessed
  # `:completed` would then pass `Check.new/1`'s status/conclusion consistency
  # rule and survive into the list. With `conclusion: nil` the guess gets caught
  # by that validation instead, and the test would pass without the mapper ever
  # being the thing under test.
  test "list_checks refuses the whole read on an unknown status rather than guessing" do
    stub_with_mint(:checks_read, fn conn ->
      Req.Test.json(conn, %{
        "total_count" => 2,
        "check_runs" => [
          %{"id" => 1, "name" => "ci/test", "status" => "completed", "conclusion" => "failure"},
          %{
            "id" => 2,
            "name" => "ci/teleport",
            "status" => "teleported",
            "conclusion" => "failure"
          }
        ]
      })
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  # "we cannot find the status" is a parse failure, not "a status we have no
  # mapping for" — the surviving `completed:failed` entry must not be reported
  # as the whole truth.
  test "list_checks refuses the whole read when a check run carries no status" do
    stub_with_mint(:checks_read, fn conn ->
      Req.Test.json(conn, %{
        "total_count" => 2,
        "check_runs" => [
          %{"id" => 1, "name" => "ci/test", "status" => "completed", "conclusion" => "failure"},
          %{"id" => 2, "name" => "ci/renamed", "conclusion" => nil}
        ]
      })
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  # Unlike `status`, `Check.conclusion` DOES declare `:other`, so an unrecognized
  # conclusion has an honest member to degrade onto. Reporting it is truthful;
  # refusing the read would be over-strict.
  test "list_checks degrades an unrecognized conclusion onto :other" do
    stub_with_mint(:checks_read, fn conn ->
      Req.Test.json(conn, %{
        "total_count" => 1,
        "check_runs" => [
          %{"id" => 9, "name" => "ci/new", "status" => "completed", "conclusion" => "stale"}
        ]
      })
    end)

    assert {:ok, [%Check{external_id: "9", status: :completed, conclusion: :other}]} =
             GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  # A 200 whose body has no `check_runs` key is a shape this code does not
  # understand. It must become a typed adapter error — not an unhandled
  # `WithClauseError`, and not `{:ok, []}`, which a caller reads as "nothing failed".
  test "list_checks refuses a body with no check_runs key instead of raising" do
    stub_with_mint(:checks_read, fn conn ->
      Req.Test.json(conn, %{"total_count" => 0})
    end)

    assert {:error, :provider_response_unrecognized} =
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

  # FILTERING and LOSING are different. A `PENDING` entry is a draft its author
  # has not submitted — GitHub documents that it carries no `submitted_at` — so
  # dropping it is the contract. Counting it invents a comment nobody made.
  test "list_reviews filters unsubmitted PENDING drafts rather than counting them" do
    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, [
        %{
          "id" => 1,
          "user" => %{"login" => "octocat"},
          "state" => "APPROVED",
          "submitted_at" => "2024-01-15T10:30:00Z"
        },
        %{"id" => 2, "user" => %{"login" => "hubot"}, "state" => "PENDING"}
      ])
    end)

    assert {:ok, [%Review{external_id: "1", state: :approved}]} =
             GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  # The failure this whole change exists for: a `CHANGES_REQUESTED` whose state
  # value drifted must not be reported as a harmless comment. `Review.state` has
  # no "unmapped" member, so the read is refused rather than guessed.
  test "list_reviews refuses the whole read on an unknown state rather than guessing" do
    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, [
        %{
          "id" => 1,
          "user" => %{"login" => "octocat"},
          "state" => "APPROVED",
          "submitted_at" => "2024-01-15T10:30:00Z"
        },
        %{
          "id" => 2,
          "user" => %{"login" => "hubot"},
          "state" => "BLOCKS_MERGE",
          "submitted_at" => "2024-01-15T11:00:00Z"
        }
      ])
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  # Same event, arriving as a renamed/absent field instead of an unknown value.
  # Returning `{:ok, [approved]}` here would erase a human's explicit objection
  # and leave the caller recording `approved=1`.
  test "list_reviews refuses the whole read when a review carries no state" do
    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, [
        %{
          "id" => 1,
          "user" => %{"login" => "octocat"},
          "state" => "APPROVED",
          "submitted_at" => "2024-01-15T10:30:00Z"
        },
        %{"id" => 2, "user" => %{"login" => "hubot"}, "submitted_at" => "2024-01-15T11:00:00Z"}
      ])
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  # An absent `submitted_at` is legitimate (a filtered draft has none); a present
  # one that will not parse is a shape failure, and silently nilling it reports a
  # submitted review as never submitted.
  test "list_reviews refuses a review whose submitted_at cannot be parsed" do
    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, [
        %{
          "id" => 1,
          "user" => %{"login" => "octocat"},
          "state" => "APPROVED",
          "submitted_at" => "last Tuesday"
        }
      ])
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  # ── scalar entries must not escape the closed result contract ───────────

  # `Access` on a scalar RAISES, and a raise leaves the callback without either
  # `{:ok, _}` or `{:error, Error.t()}` — outside the contract entirely, so the
  # caller's `with` never sees it.
  test "list_checks returns a typed error for a scalar check-run entry, never raises" do
    stub_with_mint(:checks_read, fn conn ->
      Req.Test.json(conn, %{"total_count" => 1, "check_runs" => ["unexpected"]})
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
  end

  test "list_reviews returns a typed error for a scalar review entry, never raises" do
    stub_with_mint(:change_request_read, fn conn ->
      Req.Test.json(conn, ["unexpected"])
    end)

    assert {:error, :provider_response_unrecognized} =
             GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
  end

  # `user` as a scalar is the same raise one level down; `user: null` is GitHub's
  # documented shape for a deleted account and must take the same typed path.
  test "list_reviews returns a typed error for a malformed or absent review author" do
    for user <- ["ghost", nil] do
      stub_with_mint(:change_request_read, fn conn ->
        Req.Test.json(conn, [
          %{
            "id" => 1,
            "user" => user,
            "state" => "APPROVED",
            "submitted_at" => "2024-01-15T10:30:00Z"
          }
        ])
      end)

      assert {:error, :provider_response_unrecognized} =
               GitHubAdapter.list_reviews(ctx(), repo(), change_request_id()),
             "expected refusal for user: #{inspect(user)}"
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  # The runtime union, read off the domain type's own typespec so this test
  # cannot drift from `Ezagent.DomainGit.Error` the way a restated copy would.
  defp domain_git_errors do
    {:ok, specs} = Code.Typespec.fetch_types(Ezagent.DomainGit.Error)

    {:type, _, :union, members} =
      Enum.find_value(specs, fn
        {:type, {:t, definition, _args}} -> definition
        _ -> nil
      end)

    for {:atom, _, atom} <- members, do: atom
  end

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
