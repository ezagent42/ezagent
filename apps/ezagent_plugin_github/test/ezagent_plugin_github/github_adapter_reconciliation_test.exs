defmodule EzagentPluginGithub.GitHubAdapterReconciliationTest do
  @moduledoc """
  Two-invocation crash/retry coverage for `EzagentPluginGithub.GitHubAdapter`
  (design docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §6.2). Each test calls `create_change_request/4` (or an observation
  callback) TWICE against provider state that reflects what GitHub already
  durably holds after a partial completion of call 1 -- simulating a
  workflow-level crash/restart between the two calls -- and asserts call 2
  performs no duplicate remote mutation.

  `github_adapter_test.exs` covers ONE-CALL behavior (a single invocation's
  response to a given provider state); this file covers RE-INVOCATION safety.

  Design §6.2 crash windows and where each is covered:

    * Window 1 ("commit created, head/ref update before") -- ref exists but
      still points at base, no commit has been advanced onto it yet:
      "...after a commit was created but the ref was never advanced..." below.
    * Window 2 ("head/ref updated, PR creation before") -- ref exists and is
      already advanced onto the real head commit, PR does not exist yet:
      "...after the head ref was durably advanced but the PR was not...".
    * Windows 3+4 ("PR created, fact persisted before" / "facts persisted,
      state CAS before") -- both ref and PR already fully exist; these two
      design windows are indistinguishable at the adapter's observable
      boundary, so one test covers both: "...after both the head ref and
      the PR already exist...".
    * Window 5 ("observation HTTP success, snapshot persisted before") --
      "observation callbacks are pure reads..." below.
  """

  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.{
    ChangeRequest,
    ChangeRequestId,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef
  }

  alias EzagentPluginGithub.{GitHubAdapter, InstallationPermissions, TestHelpers}

  @stub_name :github_adapter_reconciliation_test

  setup do
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
    Application.put_env(:ezagent_plugin_github, :private_key, TestHelpers.test_private_key_pem())

    # `retry: false` -- this file exercises workflow-level crash/retry (two
    # explicit, separate `create_change_request/4` invocations against an
    # ordered `Req.Test.expect` queue), a different concern from Req's own
    # transport-level auto-retry-on-5xx/429. Without disabling it, Req's
    # default `:safe_transient` retry re-issues a failed GET (e.g. the "PR
    # search fails transiently" step below) against the SAME ordered queue,
    # consuming additional entries that were never registered for that
    # purpose and desyncing the whole sequence -- not a bug in the adapter,
    # an interaction between Req's default retry and single-use `expect`
    # queues (github_client_test.exs covers Req-level retry/error-mapping
    # separately, with `Req.Test.stub`, which tolerates repeat calls).
    Application.put_env(:ezagent_plugin_github, :adapter_req_opts,
      plug: {Req.Test, @stub_name},
      retry: false
    )

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

  defp ctx do
    workspace = "test-ws"
    hash = Base.encode16(:crypto.hash(:sha256, "github-adapter-reconciliation"), case: :lower)

    {:ok, ctx} =
      OperationContext.new(%{
        task_access_uri: Ezagent.URI.worker(workspace, "gta_#{hash}"),
        caller_uri: Ezagent.URI.entity(workspace, "agent", "caller"),
        grantee_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
        credential_owner_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
        idempotency_key: "reconcile-test-idem-1"
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

  defp base_sha, do: String.duplicate("a", 40)
  defp head_sha, do: String.duplicate("b", 40)

  # Fixed, past, run-stable stand-in for `git_workflow_runs.inserted_at`
  # (design §6.1 step 5, corrected 2026-07-27 P3-fix3): the workflow
  # supplies this from the run row in production (Slice P4); this adapter
  # test supplies it directly since `create_request/0` is called fresh on
  # both call 1 and call 2 below and must hand back the SAME literal both
  # times for the commit-create bodies to be byte-identical.
  defp commit_date, do: ~U[2026-06-15 09:30:00Z]

  defp change_request_id do
    {:ok, id} = ChangeRequestId.new(%{external_id: "42"})
    id
  end

  defp commit_sha do
    {:ok, sha} = CommitSha.new(%{value: base_sha()})
    sha
  end

  defp create_request do
    {:ok, sha} = CommitSha.new(%{value: base_sha()})

    {:ok, cr} =
      CreateChangeRequest.new(%{
        title: "Test PR",
        body: "PR body text",
        head_ref: "feature-branch",
        expected_base_sha: sha,
        commit_date: commit_date()
      })

    cr
  end

  # ── Window 1: "commit created, head/ref update before" -- call 1 durably
  #    creates the marker ref (pointing at base) and the blob/tree/commit
  #    chain, but crashes before the ref-advance PATCH. Server-side, the ref
  #    exists but still points at base_sha -- there is no head commit yet to
  #    verify against. Call 2 must recognize this durable marker and resume
  #    the chain: blob/tree recreation is idempotent (content-addressed), and
  #    the commit-create POST is RE-ISSUED (this adapter has no way to look
  #    up an existing commit by content, so it cannot skip the call) but is
  #    now byte-identical to call 1's -- same tree, parents, message, and an
  #    explicit author/committer whose date is `create_req.commit_date`
  #    rather than left for GitHub to fill in (design §6.1 step 5 amendment,
  #    corrected 2026-07-27 P3-fix3) -- so GitHub's content addressing hands
  #    back the SAME sha, not a second, orphaned commit. Exactly one ref
  #    advance succeeds and exactly one PR is created. ────────────────────

  test "re-invoking create_change_request after a commit was created but the ref was never advanced past base recovers by reproducing the identical commit sha, not a second orphan" do
    test_pid = self()

    # Call 1: the marker ref is created pointing at base, then blob/tree/
    # commit all succeed, but the workflow crashes before the ref-advance
    # PATCH -- design §6.2's first crash window. The ref exists server-side,
    # but it still points at base_sha, not at the new (as yet unreferenced)
    # commit.
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/refs"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => base_sha(),
        "tree" => %{"sha" => "tree_base"},
        "parents" => []
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:commit_body, 1, Jason.decode!(raw_body)})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => head_sha()})
    end)

    # Simulated crash: the ref-advance PATCH never happens in call 1.
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 503, ~s({"message": "Service Unavailable"}))
    end)

    assert {:error, :provider_unavailable} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # Call 2 (the retry): the head ref exists but is STILL at base_sha -- the
    # durable marker this design's ordering exists to produce, not an
    # existing head commit to verify. The chain resumes: blob/tree are
    # recreated (idempotent, content-addressed -- no new objects), and the
    # commit-create POST is re-issued with the SAME tree/parents/message/
    # author/committer/date as call 1's -- reproducing call 1's sha rather
    # than minting a second one -- and the ref advances for the first time.
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => base_sha(),
        "tree" => %{"sha" => "tree_base"},
        "parents" => []
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:commit_body, 2, Jason.decode!(raw_body)})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => head_sha()})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/refs/heads/feature-branch"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"sha" => head_sha(), "force" => false}
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
        "head" => %{"ref" => "feature-branch", "sha" => head_sha()},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # The mechanism, not just the outcome: call 1 and call 2's commit-create
    # request bodies must be byte-identical, INCLUDING `date` -- that is what
    # makes GitHub's content addressing return call 1's exact sha for call 2
    # as well, rather than this test merely mocking a coincidentally-matching
    # response. (Both mocks above return the same `head_sha()` regardless of
    # what was sent -- asserting only that would pass even if the adapter
    # still minted a fresh, different commit every time.)
    assert_received {:commit_body, 1, commit_body_1}
    assert_received {:commit_body, 2, commit_body_2}
    assert commit_body_1 == commit_body_2
    assert commit_body_1["committer"] == commit_body_1["author"]

    # And that shared date is exactly the `commit_date()` value
    # `create_request/0` supplied -- not wall-clock "now" wearing a
    # disguise. A regression back to reading the clock at commit-creation
    # time would produce a date near the moment this test ran, not this
    # fixed, deliberately past literal.
    assert commit_body_1["author"]["date"] == DateTime.to_iso8601(commit_date())
    {:ok, author_date, _offset} = DateTime.from_iso8601(commit_body_1["author"]["date"])
    assert DateTime.diff(DateTime.utc_now(), author_date) |> abs() > 86_400

    # No further Req.Test.expect entries are registered for either call: a
    # second ref-CREATE (POST /git/refs), a second ref-advance, or a second
    # PR search miss followed by another PR POST would exhaust the queue and
    # raise. Call 2's commit-create POST reproduces call 1's exact sha
    # (`head_sha()`) -- there is no second, orphaned commit left behind.
  end

  # ── Window 2: "head/ref updated, PR creation before" -- call 1 durably
  #    advances the head ref onto the real commit server-side but fails
  #    before/while creating the PR (simulating the workflow crashing
  #    anywhere in that span and retrying from scratch). Call 2 must
  #    reconcile the now-existing, already-advanced head ref without
  #    recreating any git data, then create exactly one PR. ─────────────

  test "re-invoking create_change_request after the head ref was durably advanced but the PR was not finds the ref and creates exactly one PR" do
    # Call 1: fresh create all the way through the ref advance, then the PR
    # search fails transiently (simulating a crash/network failure before
    # the PR could be found-or-created). The ref is now durably advanced
    # onto the real head commit server-side even though call 1 itself
    # returns an error.
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => base_sha(),
        "tree" => %{"sha" => "tree_base"},
        "parents" => []
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => head_sha()})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    # PR search fails transiently -- call 1 returns an error, but the ref
    # above was already durably advanced.
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 503, ~s({"message": "Service Unavailable"}))
    end)

    assert {:error, :provider_unavailable} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # Call 2 (the retry): the head ref now exists server-side, already
    # advanced past base, with a parent and tree matching this call's own --
    # reconcile it (Fix 2's tree check), skip creating any new git data, and
    # create exactly one PR.
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha(),
        "tree" => %{"sha" => "tree_match"},
        "parents" => [%{"sha" => base_sha()}]
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => base_sha(),
        "tree" => %{"sha" => "tree_base"},
        "parents" => []
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => "tree_match"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => head_sha()},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # No further Req.Test.expect entries are registered for either call: had
    # the implementation attempted to recreate the ref (a second POST
    # /git/refs), re-advance it (a second PATCH), or blindly re-POST the PR
    # without searching first, the exhausted ordered-expect queue would
    # raise instead of these two calls completing cleanly.
  end

  # ── Windows 3+4: "after PR creation succeeds, before the workflow fact is
  #    persisted" and "after facts persist, before the state CAS" -- call 1
  #    fully succeeds (ref + PR both created). Call 2 (the workflow retrying
  #    because it crashed before durably recording call 1's success) must
  #    fresh-read the existing ref and PR and create no new commit, ref, or
  #    PR (Fix 2's tree-provenance check still issues idempotent blob/tree
  #    POSTs -- content-addressed no-ops, not new data). These two design
  #    windows are indistinguishable at the adapter's observable boundary --
  #    both present as "everything already exists" on re-invocation -- so one
  #    test covers both. ────────────────────────────────────────────────

  test "re-invoking create_change_request after both the head ref and the PR already exist creates no new commit, ref, or PR" do
    # Call 1: full fresh create, succeeds completely.
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => base_sha(),
        "tree" => %{"sha" => "tree_base"},
        "parents" => []
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => head_sha()})
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
        "head" => %{"ref" => "feature-branch", "sha" => head_sha()},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42"}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # Call 2 (the retry): both the ref and the PR already exist. Fix 2's
    # tree-provenance round trip (idempotent blob/tree creation) still runs
    # before the PR search -- but no commit, ref, or PR write happens.
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha()}})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha(),
        "tree" => %{"sha" => "tree_match"},
        "parents" => [%{"sha" => base_sha()}]
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => base_sha(),
        "tree" => %{"sha" => "tree_base"},
        "parents" => []
      })
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
          "head" => %{"ref" => "feature-branch", "sha" => head_sha()},
          "base" => %{"ref" => "main"},
          "merged" => false
        }
      ])
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  # ── Window 5: "after an observation HTTP success, before the snapshot
  #    persists" -- read_change_request/list_checks/list_reviews are pure
  #    reads with nothing to duplicate. Proven explicitly rather than assumed:
  #    the stub below flunks on any non-GET, non-mint request, so an
  #    accidental write anywhere in these three callbacks fails this test. ──

  test "observation callbacks are pure reads -- repeated calls make zero mutating requests and return consistent facts" do
    sha = base_sha()

    Req.Test.stub(@stub_name, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/owner/repo/installation"} ->
          Req.Test.json(conn, %{"id" => 123})

        {"POST", "/app/installations/123/access_tokens"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          {:ok, decoded} = Jason.decode(body)

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "token" => "ghs-test-token",
            "expires_at" => future_iso(),
            "repository_selection" => "selected",
            "repositories" => [%{"full_name" => "owner/repo"}],
            "permissions" => decoded["permissions"]
          })

        {"GET", "/repos/owner/repo/pulls/42"} ->
          Req.Test.json(conn, %{
            "number" => 42,
            "html_url" => "https://github.com/owner/repo/pull/42",
            "state" => "open",
            "head" => %{"ref" => "feature-branch", "sha" => sha},
            "base" => %{"ref" => "main"},
            "merged" => false
          })

        {"GET", "/repos/owner/repo/commits/" <> _rest} ->
          Req.Test.json(conn, %{"total_count" => 0, "check_runs" => []})

        {"GET", "/repos/owner/repo/pulls/42/reviews"} ->
          Req.Test.json(conn, [])

        {method, path} ->
          flunk("observation must be read-only; got #{method} #{path}")
      end
    end)

    read_1 = GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
    read_2 = GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} = read_1
    assert read_1 == read_2

    checks_1 = GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
    checks_2 = GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
    assert {:ok, []} = checks_1
    assert checks_1 == checks_2

    reviews_1 = GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
    reviews_2 = GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
    assert {:ok, []} = reviews_1
    assert reviews_1 == reviews_2
  end
end
