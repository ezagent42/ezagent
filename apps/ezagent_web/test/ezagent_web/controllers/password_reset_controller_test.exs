defmodule EzagentWeb.PasswordResetControllerTest do
  use EzagentWeb.ConnCase

  alias Ezagent.Entity.{MagicLinkToken, Profile}
  alias Ezagent.Users
  alias EzagentWeb.RateLimiter

  setup do
    RateLimiter.reset_all()
    :ok
  end

  defp seed_user(email) do
    n = System.unique_integer([:positive])
    uri = "entity://team-alpha/user/rst#{n}"
    {:ok, _} = Users.create(uri, "oldpassword", [])
    {:ok, _} = Profile.upsert(%{entity_uri: uri, display_name: "Rst", email: email})
    uri
  end

  test "GET /auth/reset renders the request form", %{conn: conn} do
    body = conn |> get("/auth/reset") |> html_response(200)
    assert body =~ ~s(name="email")
    assert body =~ "Reset your password"
  end

  test "POST /auth/reset is generic for an unknown email (no token minted)", %{conn: conn} do
    before = EzagentCore.Repo.aggregate(MagicLinkToken, :count)

    body =
      conn
      |> post("/auth/reset", %{"email" => "nobody#{System.unique_integer([:positive])}@ex.com"})
      |> html_response(200)

    assert body =~ "Check your email"
    assert EzagentCore.Repo.aggregate(MagicLinkToken, :count) == before
  end

  test "POST /auth/reset mints a :reset token for an existing account", %{conn: conn} do
    email = "exists#{System.unique_integer([:positive])}@ex.com"
    _uri = seed_user(email)
    before = EzagentCore.Repo.aggregate(MagicLinkToken, :count)

    conn |> post("/auth/reset", %{"email" => email})
    assert EzagentCore.Repo.aggregate(MagicLinkToken, :count) == before + 1
  end

  test "GET /auth/reset/:token renders the set-new-password form", %{conn: conn} do
    body = conn |> get("/auth/reset/sometoken") |> html_response(200)
    assert body =~ "Set a new password"
    assert body =~ ~s(name="password")
  end

  test "full reset cycle: token → set new password → login works with the new one", %{conn: conn} do
    email = "cycle#{System.unique_integer([:positive])}@ex.com"
    uri = seed_user(email)
    {:ok, token} = MagicLinkToken.mint(email, purpose: "reset")

    conn = post(conn, "/auth/reset/#{token}", %{"password" => "brandnew123"})
    assert redirected_to(conn) == "/login"
    refute Users.verify_password(uri, "oldpassword")
    assert Users.verify_password(uri, "brandnew123")
  end

  test "a login-purpose token cannot be used at the reset endpoint", %{conn: conn} do
    email = "wp#{System.unique_integer([:positive])}@ex.com"
    uri = seed_user(email)
    {:ok, token} = MagicLinkToken.mint(email, purpose: "login")

    conn = post(conn, "/auth/reset/#{token}", %{"password" => "brandnew123"})
    assert redirected_to(conn) == "/login"
    # password unchanged
    assert Users.verify_password(uri, "oldpassword")
  end

  test "short password is rejected with an error, token not consumed", %{conn: conn} do
    email = "short#{System.unique_integer([:positive])}@ex.com"
    _uri = seed_user(email)
    {:ok, token} = MagicLinkToken.mint(email, purpose: "reset")

    body = conn |> post("/auth/reset/#{token}", %{"password" => "short"}) |> html_response(200)
    assert body =~ "at least 8 characters"
    # token still usable afterwards (not burned)
    assert {:ok, ^email} = MagicLinkToken.consume(token, "reset")
  end
end
