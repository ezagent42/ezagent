defmodule EzagentWeb.MagicLinkControllerTest do
  use EzagentWeb.ConnCase

  alias Ezagent.Entity.{MagicLinkToken, Profile}

  test "consuming a login token for an existing user logs them in", %{conn: conn} do
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://team-alpha/user/known",
        display_name: "Known",
        email: "known@good.com"
      })

    {:ok, _} = Ezagent.Users.create("entity://team-alpha/user/known", nil, [])
    {:ok, raw} = MagicLinkToken.mint("known@good.com")

    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/sessions"
    assert get_session(conn, :current_entity_uri) == "entity://team-alpha/user/known"
  end

  # task #87 — magic-link no longer creates accounts. A link for an email with
  # no account routes the visitor to email+password registration.
  test "consuming a login token for a new email routes to /register", %{conn: conn} do
    {:ok, raw} = MagicLinkToken.mint("newcomer@good.com")

    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/register"
  end

  # task #87 (codex final-review HIGH) — an UNCONFIRMED account must not be able
  # to log in via a magic link (would bypass the email_verified gate).
  test "an unconfirmed account cannot log in via magic-link", %{conn: conn} do
    uri = "entity://team-alpha/user/unconf#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Users.create(uri, nil, [], email_verified: false)
    email = "unconf#{System.unique_integer([:positive])}@good.com"
    {:ok, _} = Profile.upsert(%{entity_uri: uri, display_name: "U", email: email})
    {:ok, raw} = MagicLinkToken.mint(email)

    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/login"
    refute get_session(conn, :current_entity_uri)
  end

  # task #87 — a non-login-purpose token (e.g. a password-reset token) cannot be
  # replayed at the magic-link login endpoint.
  test "a reset-purpose token is rejected at the login endpoint", %{conn: conn} do
    {:ok, raw} = MagicLinkToken.mint("known@good.com", purpose: "reset")
    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/login"
  end

  test "an invalid token redirects to /login with an error", %{conn: conn} do
    conn = get(conn, "/auth/magic/bogus-token")
    assert redirected_to(conn) == "/login"
  end

  test "a consumed (replayed) token redirects to /login" do
    {:ok, raw} = MagicLinkToken.mint("replay@good.com")

    # first click consumes it (new email → /register)
    first = get(build_conn(), "/auth/magic/#{raw}")
    assert redirected_to(first) == "/register"

    # second click — token already consumed → /login with error
    second = get(build_conn(), "/auth/magic/#{raw}")
    assert redirected_to(second) == "/login"
  end
end
