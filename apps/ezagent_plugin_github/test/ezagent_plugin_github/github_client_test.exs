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

  test "get maps 403 to provider_denied (rate limit / forbidden)" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :provider_denied} =
             GitHubClient.get("/repos/owner/private-repo", "token", plug: {Req.Test, @stub_name})
  end

  test "get maps 422 to change_request_conflict" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 422, ~s({"message": "Validation error"}))
    end)

    assert {:error, :change_request_conflict} =
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

  test "post maps 422 to change_request_conflict" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 422, ~s({"message": "Validation error"}))
    end)

    assert {:error, :change_request_conflict} =
             GitHubClient.post("/repos/owner/repo/issues", "token", %{title: "Bad"},
               plug: {Req.Test, @stub_name}
             )
  end
end
