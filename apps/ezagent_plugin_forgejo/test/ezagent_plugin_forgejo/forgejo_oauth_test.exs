defmodule EzagentPluginForgejo.ForgejoOAuthTest do
  use ExUnit.Case, async: true

  alias EzagentPluginForgejo.ForgejoOAuth

  @stub_name :forgejo_oauth_test

  @app %{
    host: "code.hyprial.test",
    client_id: "client-abc",
    client_secret: "secret-xyz",
    redirect_uri: "https://ezagent.test/forgejo/callback"
  }

  # Long enough to be a plausible RFC 7636 verifier.
  @verifier "dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"

  defp stub(fun) do
    Req.Test.stub(@stub_name, fun)
    [plug: {Req.Test, @stub_name}]
  end

  describe "authorize_url/3" do
    setup do
      {:ok, url} = ForgejoOAuth.authorize_url(@app, "state-123", @verifier)
      uri = URI.parse(url)
      {:ok, uri: uri, query: URI.decode_query(uri.query || "")}
    end

    # Self-hosted: the endpoint follows the binding's host. A module constant
    # would send every tenant's users to one instance.
    test "is addressed to the app's own instance", %{uri: uri} do
      assert uri.scheme == "https"
      assert uri.host == "code.hyprial.test"
      assert uri.path == "/login/oauth/authorize"
    end

    test "carries the authorization-code parameters", %{query: q} do
      assert q["response_type"] == "code"
      assert q["client_id"] == "client-abc"
      assert q["redirect_uri"] == "https://ezagent.test/forgejo/callback"
      assert q["state"] == "state-123"
    end

    # Measured: the target instance accepts S256. Sending the raw verifier
    # (`plain`) would put it in the browser's URL bar and in server logs.
    test "sends an S256 PKCE challenge, never the verifier", %{query: q} do
      expected = :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false)

      assert q["code_challenge_method"] == "S256"
      assert q["code_challenge"] == expected
      refute q["code_challenge"] == @verifier
    end

    test "requests repository write and user read", %{query: q} do
      scopes = String.split(q["scope"] || "", " ", trim: true)
      assert "write:repository" in scopes
      assert "read:user" in scopes
    end

    test "never leaks the client secret into the browser-bound URL", %{uri: uri} do
      refute URI.to_string(uri) =~ "secret-xyz"
    end

    test "rejects a malformed host rather than addressing another server" do
      assert {:error, :invalid_provider_host} =
               ForgejoOAuth.authorize_url(%{@app | host: "https://evil.test"}, "s", @verifier)
    end
  end

  describe "exchange_code/4" do
    test "posts the form-encoded grant with the PKCE verifier" do
      opts =
        stub(fn conn ->
          assert conn.host == "code.hyprial.test"
          assert conn.request_path == "/login/oauth/access_token"

          {:ok, body, conn} = Plug.Conn.read_body(conn)
          form = URI.decode_query(body)

          assert form["grant_type"] == "authorization_code"
          assert form["code"] == "the-code"
          assert form["code_verifier"] == @verifier
          assert form["client_id"] == "client-abc"
          assert form["client_secret"] == "secret-xyz"
          assert form["redirect_uri"] == "https://ezagent.test/forgejo/callback"

          Req.Test.json(conn, %{
            "access_token" => "at-1",
            "refresh_token" => "rt-1",
            "token_type" => "bearer",
            "expires_in" => 3600
          })
        end)

      assert {:ok, tokens} = ForgejoOAuth.exchange_code(@app, "the-code", @verifier, opts)
      assert tokens.access_token == "at-1"
      assert tokens.refresh_token == "rt-1"
    end

    # Measured: expires_in is 3600. The domain stores an absolute expires_at,
    # so a relative lifetime that is never anchored is a silently-expiring
    # credential.
    test "anchors expires_in onto an absolute expires_at" do
      opts =
        stub(fn conn ->
          Req.Test.json(conn, %{
            "access_token" => "at-1",
            "refresh_token" => "rt-1",
            "expires_in" => 3600
          })
        end)

      before = DateTime.utc_now()
      assert {:ok, tokens} = ForgejoOAuth.exchange_code(@app, "c", @verifier, opts)

      elapsed = DateTime.diff(tokens.expires_at, before)
      assert elapsed >= 3595 and elapsed <= 3605
    end

    test "a response without an access token is a protocol failure" do
      opts = stub(fn conn -> Req.Test.json(conn, %{"error" => "invalid_grant"}) end)

      assert {:error, :provider_protocol_failed} =
               ForgejoOAuth.exchange_code(@app, "c", @verifier, opts)
    end

    test "a 400 is a protocol failure, not a crash" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 400, ~s({"error":"invalid_request"})) end)

      assert {:error, :provider_protocol_failed} =
               ForgejoOAuth.exchange_code(@app, "c", @verifier, opts)
    end

    # A lost response leaves the remote state unknown: the code may already be
    # consumed. Callers must be able to tell this apart from a refusal.
    test "a transport failure is distinguishable from a refusal" do
      opts = stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, :provider_unreachable} =
               ForgejoOAuth.exchange_code(@app, "c", @verifier, opts)
    end
  end

  describe "refresh/3" do
    # Measured: Forgejo rotates the refresh token. Keeping the old one would
    # work until the first rotation, then fail permanently.
    test "sends the refresh grant and returns the rotated pair" do
      opts =
        stub(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          form = URI.decode_query(body)

          assert form["grant_type"] == "refresh_token"
          assert form["refresh_token"] == "rt-old"
          assert form["client_id"] == "client-abc"
          assert form["client_secret"] == "secret-xyz"

          Req.Test.json(conn, %{
            "access_token" => "at-2",
            "refresh_token" => "rt-new",
            "expires_in" => 3600
          })
        end)

      assert {:ok, tokens} = ForgejoOAuth.refresh(@app, "rt-old", opts)
      assert tokens.access_token == "at-2"
      assert tokens.refresh_token == "rt-new"
      refute tokens.refresh_token == "rt-old"
    end

    test "a rejected refresh token is a protocol failure" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 400, ~s({"error":"invalid_grant"})) end)

      assert {:error, :provider_protocol_failed} = ForgejoOAuth.refresh(@app, "rt-old", opts)
    end
  end
end
