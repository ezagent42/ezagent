defmodule EzagentPluginGithub.GitHubClientTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGithub.GitHubClient

  @stub_name :github_client_test

  test "get injects Authorization and Accept headers" do
    Req.Test.stub(@stub_name, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github+json"]
      Req.Test.json(conn, %{"login" => "test-user"})
    end)

    assert {:ok, %{"login" => "test-user"}} =
             GitHubClient.get("/user", "test-token", plug: {Req.Test, @stub_name})
  end

  test "get maps 401 to authentication_rejected" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"message": "Bad credentials"}))
    end)

    assert {:error, :authentication_rejected} =
             GitHubClient.get("/user", "bad-token", plug: {Req.Test, @stub_name})
  end

  test "get maps 404 to repository_not_found" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :repository_not_found} =
             GitHubClient.get("/repos/owner/nonexistent", "token", plug: {Req.Test, @stub_name})
  end

  test "get maps a plain 403 (no rate-limit signal) to provider_denied" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :provider_denied} =
             GitHubClient.get("/repos/owner/private-repo", "token", plug: {Req.Test, @stub_name})
  end

  test "get maps a 403 with x-ratelimit-remaining: 0 to provider_rate_limited" do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
      |> Plug.Conn.resp(403, ~s({"message": "API rate limit exceeded"}))
    end)

    assert {:error, :provider_rate_limited} =
             GitHubClient.get("/repos/owner/repo", "token", plug: {Req.Test, @stub_name})
  end

  test "get maps a 403 with retry-after to provider_rate_limited" do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "30")
      |> Plug.Conn.resp(403, ~s({"message": "You have exceeded a secondary rate limit"}))
    end)

    assert {:error, :provider_rate_limited} =
             GitHubClient.get("/repos/owner/repo", "token", plug: {Req.Test, @stub_name})
  end

  test "get maps 422 to unprocessable_entity, not a guessed identity" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 422, ~s({"message": "Validation error"}))
    end)

    assert {:error, :unprocessable_entity} =
             GitHubClient.get("/repos/owner/repo/pulls", "token", plug: {Req.Test, @stub_name})
  end

  test "get maps other 4xx/5xx to provider_unavailable" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"message": "Internal Server Error"}))
    end)

    assert {:error, :provider_unavailable} =
             GitHubClient.get("/repos/owner/repo", "token", plug: {Req.Test, @stub_name})
  end

  test "get maps 429 to provider_rate_limited" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 429, ~s({"message": "You have exceeded a secondary rate limit"}))
    end)

    assert {:error, :provider_rate_limited} =
             GitHubClient.get("/repos/owner/repo", "token", plug: {Req.Test, @stub_name})
  end

  # ---------------------------------------------------------------------------
  # #1613 — the transport layer must not retry
  # ---------------------------------------------------------------------------

  describe "no transport-level retry (#1613)" do
    # Req 0.6's default is `:safe_transient`: 408/429/500/502/503/504 get three
    # retries with 1s/2s/4s backoff. Counting the requests is the only way to
    # say this is off — the returned error atom is identical either way, which
    # is exactly how the default survived unnoticed.
    test "a retryable-by-default status is requested exactly ONCE" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, :github_request)
        Plug.Conn.resp(conn, 500, ~s({"message": "Internal Server Error"}))
      end)

      assert {:error, :provider_unavailable} =
               GitHubClient.get("/repos/owner/repo", "token", plug: {Req.Test, @stub_name})

      assert_received :github_request
      refute_received :github_request
    end

    # 429 is the one that matters most: retrying into a rate limit deepens it,
    # and GitHub's 429 means "stop", not "try three more times".
    test "a 429 is requested exactly ONCE — retrying into a limit deepens it" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, :github_request)
        Plug.Conn.resp(conn, 429, ~s({"message": "rate limited"}))
      end)

      assert {:error, :provider_rate_limited} =
               GitHubClient.get("/repos/owner/repo", "token", plug: {Req.Test, @stub_name})

      assert_received :github_request
      refute_received :github_request
    end

    # HONEST SCOPE: Req's default `:safe_transient` retries GET/HEAD ONLY
    # (`deps/req/lib/req/steps.ex:2223`), so POST/PATCH were never multiplied
    # even before #1613 — this test does NOT go red if `retry: false` is
    # removed, and it is not claimed to. What it guards is a FUTURE switch to
    # `:transient` (which does retry every method), where a retried POST would
    # mean a duplicate ref/commit/PR create — the exact duplicate-mutation
    # class design §6.2 is built to prevent.
    test "post and patch make exactly one request (guards a future :transient)" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, :github_request)
        Plug.Conn.resp(conn, 503, ~s({"message": "unavailable"}))
      end)

      assert {:error, :provider_unavailable} =
               GitHubClient.post("/repos/owner/repo/git/refs", "token", %{ref: "x"},
                 plug: {Req.Test, @stub_name}
               )

      assert_received :github_request
      refute_received :github_request

      assert {:error, :provider_unavailable} =
               GitHubClient.patch("/repos/owner/repo/git/refs/heads/x", "token", %{sha: "abc"},
                 plug: {Req.Test, @stub_name}
               )

      assert_received :github_request
      refute_received :github_request
    end

    # The escape hatch is deliberate: `opts` merges LAST, so a call site with a
    # genuine transport-retry need opts back in explicitly and reviewably.
    test "a caller can still opt back in, because opts merge last" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, :github_request)
        Plug.Conn.resp(conn, 500, ~s({"message": "boom"}))
      end)

      assert {:error, :provider_unavailable} =
               GitHubClient.get("/repos/owner/repo", "token",
                 plug: {Req.Test, @stub_name},
                 retry: :safe_transient,
                 retry_delay: 0,
                 max_retries: 1
               )

      assert_received :github_request
      assert_received :github_request
    end
  end

  test "post injects Authorization and Accept headers and sends JSON body" do
    Req.Test.stub(@stub_name, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github+json"]
      assert conn.method == "POST"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 42})
    end)

    assert {:ok, %{"id" => 42}} =
             GitHubClient.post("/repos/owner/repo/issues", "test-token", %{title: "Test"},
               plug: {Req.Test, @stub_name}
             )
  end

  test "post maps 422 to unprocessable_entity, not a guessed identity" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 422, ~s({"message": "Validation error"}))
    end)

    assert {:error, :unprocessable_entity} =
             GitHubClient.post("/repos/owner/repo/issues", "token", %{title: "Bad"},
               plug: {Req.Test, @stub_name}
             )
  end
end
