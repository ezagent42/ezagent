defmodule EzagentWeb.MagicLinkControllerTest do
  use EzagentWeb.ConnCase

  alias Ezagent.Entity.{MagicLinkToken, Profile}

  test "consuming a token for an existing user logs them in", %{conn: conn} do
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://user/default/known",
        display_name: "Known",
        email: "known@good.com"
      })

    {:ok, _} = Ezagent.Users.create("entity://user/default/known", nil, [])
    {:ok, raw} = MagicLinkToken.mint("known@good.com")

    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/sessions"
    assert get_session(conn, :current_entity_uri) == "entity://user/default/known"
  end

  test "consuming a token for a new email starts registration", %{conn: conn} do
    {:ok, raw} = MagicLinkToken.mint("newcomer@good.com")

    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/register/complete"
    assert get_session(conn, :pending_registration_email) == "newcomer@good.com"
  end

  test "an invalid token redirects to /login with an error", %{conn: conn} do
    conn = get(conn, "/auth/magic/bogus-token")
    assert redirected_to(conn) == "/login"
  end

  test "a consumed token for an UNREGISTERED user re-enters /register/complete (Allen 2026-05-24 UX fix)" do
    # User clicks link → /register/complete → closes tab without
    # filling form → clicks SAME link again. Per the UX fix, the
    # second click should re-route to /register/complete (let them
    # finish), NOT bounce to /login with "already used" error.
    {:ok, raw} = MagicLinkToken.mint("pending@good.com")

    # First click — consumes the token + redirects to /register/complete
    first = get(build_conn(), "/auth/magic/#{raw}")
    assert redirected_to(first) == "/register/complete"
    assert get_session(first, :pending_registration_email) == "pending@good.com"

    # Second click of the SAME (now-consumed) link — UX fix re-routes
    # back to /register/complete with the email restored in session
    second = get(build_conn(), "/auth/magic/#{raw}")
    assert redirected_to(second) == "/register/complete"
    assert get_session(second, :pending_registration_email) == "pending@good.com"
  end

  test "a consumed token for an ALREADY-REGISTERED user redirects to /login with info msg" do
    # Edge case: user registered AND completed setup elsewhere; an
    # older email link still works → tell them clearly + bounce to
    # /login (so they can sign in with password OR request a fresh
    # magic link).
    {:ok, _} =
      Profile.upsert(%{
        entity_uri: "entity://user/default/already-registered-target",
        display_name: "Target",
        email: "already-registered@good.com"
      })

    {:ok, _} = Ezagent.Users.create("entity://user/default/already-registered-target", nil, [])

    {:ok, raw} = MagicLinkToken.mint("already-registered@good.com")

    # First click — logs them in successfully (token gets consumed)
    first = get(build_conn(), "/auth/magic/#{raw}")
    assert redirected_to(first) == "/sessions"

    # Second click of the same link — token consumed + email IS
    # registered → /login with the info message
    second = get(build_conn(), "/auth/magic/#{raw}")
    assert redirected_to(second) == "/login"
  end
end
