defmodule EzagentPluginGithub.GitHubOAuthTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGithub.GitHubOAuth

  @stub_name :github_oauth_test

  setup do
    Application.put_env(:ezagent_plugin_github, :client_id, "test-client-id")
    Application.put_env(:ezagent_plugin_github, :client_secret, "test-client-secret")

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :client_id)
      Application.delete_env(:ezagent_plugin_github, :client_secret)
    end)

    :ok
  end

  describe "authorize_url/2" do
    test "constructs correct GitHub OAuth URL with state" do
      url = GitHubOAuth.authorize_url("https://ezagent.example/callback", "state-abc")
      uri = URI.parse(url)

      assert uri.host == "github.com"
      assert uri.path == "/login/oauth/authorize"
      query = URI.decode_query(uri.query)
      assert query["client_id"] == "test-client-id"
      assert query["state"] == "state-abc"
      assert query["redirect_uri"] == "https://ezagent.example/callback"
      # A GitHub App's user-to-server OAuth takes NO scope — repo access comes
      # from the installation, not the user token.
      refute Map.has_key?(query, "scope")
    end

    test "uses different state for each invocation" do
      url1 = GitHubOAuth.authorize_url("https://ezagent.example/callback", "state-1")
      url2 = GitHubOAuth.authorize_url("https://ezagent.example/callback", "state-2")

      q1 = URI.decode_query(URI.parse(url1).query)
      q2 = URI.decode_query(URI.parse(url2).query)

      assert q1["state"] == "state-1"
      assert q2["state"] == "state-2"
    end
  end

  describe "exchange_code/3" do
    test "successfully exchanges code for access token" do
      Req.Test.stub(@stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/login/oauth/access_token"
        Req.Test.json(conn, %{"access_token" => "ghu_test_token_123"})
      end)

      assert {:ok, %{access_token: "ghu_test_token_123"}} =
               GitHubOAuth.exchange_code("test-code", "https://example.com/callback",
                 plug: {Req.Test, @stub_name}
               )
    end

    test "returns provider_denied on 400 response" do
      Req.Test.stub(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "bad_verification_code"})
      end)

      assert {:error, :provider_denied} =
               GitHubOAuth.exchange_code("bad-code", "https://example.com/callback",
                 plug: {Req.Test, @stub_name}
               )
    end

    test "returns backend_unavailable on 5xx response" do
      Req.Test.stub(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "unavailable"})
      end)

      assert {:error, :backend_unavailable} =
               GitHubOAuth.exchange_code("code", "https://example.com/callback",
                 plug: {Req.Test, @stub_name}
               )
    end
  end
end
