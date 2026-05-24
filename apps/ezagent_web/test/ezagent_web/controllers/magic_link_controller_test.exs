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

  test "consuming a token for a new email starts onboarding (PR-B SPEC v2)", %{conn: conn} do
    # PR-B 2026-05-24 (Allen) — new emails first pick a workspace
    # in /onboarding/workspace; /register/complete is the second step.
    {:ok, raw} = MagicLinkToken.mint("newcomer@good.com")

    conn = get(conn, "/auth/magic/#{raw}")
    assert redirected_to(conn) == "/onboarding/workspace"
    assert get_session(conn, :pending_registration_email) == "newcomer@good.com"
  end

  test "an invalid token redirects to /login with an error", %{conn: conn} do
    conn = get(conn, "/auth/magic/bogus-token")
    assert redirected_to(conn) == "/login"
  end

  test "a consumed token for an UNREGISTERED user re-enters /onboarding/workspace (PR-B SPEC v2 update of Allen UX fix)" do
    # User clicks link → /onboarding/workspace → closes tab without
    # picking a workspace → clicks SAME link again. Per the UX fix,
    # the second click should re-route to /onboarding/workspace (let
    # them finish), NOT bounce to /login with "already used" error.
    # PR-B 2026-05-24: same UX rule, just one step earlier in the flow
    # (workspace pick is now step 1, registration is step 2).
    {:ok, raw} = MagicLinkToken.mint("pending@good.com")

    # First click — consumes the token + redirects to /onboarding/workspace
    first = get(build_conn(), "/auth/magic/#{raw}")
    assert redirected_to(first) == "/onboarding/workspace"
    assert get_session(first, :pending_registration_email) == "pending@good.com"

    # Second click of the SAME (now-consumed) link — UX fix re-routes
    # back to /onboarding/workspace with the email restored in session
    second = get(build_conn(), "/auth/magic/#{raw}")
    assert redirected_to(second) == "/onboarding/workspace"
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
