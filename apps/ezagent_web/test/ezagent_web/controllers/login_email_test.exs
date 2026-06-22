defmodule EzagentWeb.LoginEmailTest do
  use EzagentWeb.ConnCase

  alias EzagentWeb.RateLimiter

  setup do
    RateLimiter.reset_all()

    Ezagent.AppSettings.put("smtp_config", %{
      "host" => "localhost",
      "port" => 2525,
      "username" => "u",
      "password" => "p",
      "from_address" => "no-reply@test.local"
    })

    # SPEC v2 PR-A/B/C: the magic-link gate now consults per-workspace
    # `magic_link_rule` rows, NOT the legacy `registration_domains`
    # AppSetting. Create a workspace with a domain rule for the test
    # email's domain so the send-side `email_allowed?/1` returns true.
    _ = Ezagent.Workspace.create("good-test", %{})
    _ = Ezagent.Workspace.add_magic_link_rule("workspace://good-test", "domain", "good.com")
    :ok
  end

  test "GET /login renders the email form", %{conn: conn} do
    conn = get(conn, "/login")
    assert html_response(conn, 200) =~ "email"
  end

  test "POST /login with any email shows the generic check-inbox response", %{conn: conn} do
    conn = post(conn, "/login/magic", %{"email" => "someone@bad.com"})
    assert html_response(conn, 200) =~ "check"
  end

  test "POST /login mints a token for an allowlisted new email", %{conn: conn} do
    post(conn, "/login/magic", %{"email" => "fresh@good.com"})
    assert EzagentCore.Repo.aggregate(Ezagent.Entity.MagicLinkToken, :count) >= 1
  end

  test "POST /login mints no token for a non-allowlisted new email", %{conn: conn} do
    before = EzagentCore.Repo.aggregate(Ezagent.Entity.MagicLinkToken, :count)
    post(conn, "/login/magic", %{"email" => "fresh@bad.com"})
    assert EzagentCore.Repo.aggregate(Ezagent.Entity.MagicLinkToken, :count) == before
  end

  # 2026-05-26 (Allen — magic-link login failure): a User provisioned
  # via `mix ezagent.user.create` + `mix ezagent.user.set_password` has
  # NO email on file (`entity_profiles` is empty for that URI). When
  # the operator binds an email via `Ezagent.Entity.Profile.upsert/1`
  # (or the new `mix ezagent.user.set_email` task), magic-link login
  # MUST route via the "existing principal" branch regardless of any
  # workspace's `magic_link_rule` — the user is already authenticated
  # as a member of the system, so the rule allowlist (which gates new
  # registrations) does not apply.
  test "POST /login mints a token for an existing principal whose email is bound, even when no workspace rule covers the domain",
       %{conn: conn} do
    # The email's domain is `bad.com` — NOT in the seeded `good-test`
    # workspace's domain rule. If the registration `email_allowed?/1`
    # gate were the only path, this would silently drop. The existing-
    # principal short-circuit in `send_allowed?/1` is what saves it.
    {:ok, _} = Ezagent.Users.create("entity://system/user/bound-user", nil, [])

    {:ok, _} =
      Ezagent.Entity.Profile.upsert(%{
        entity_uri: "entity://system/user/bound-user",
        display_name: "Bound User",
        email: "bound@bad.com"
      })

    before = EzagentCore.Repo.aggregate(Ezagent.Entity.MagicLinkToken, :count)
    post(conn, "/login/magic", %{"email" => "bound@bad.com"})

    assert EzagentCore.Repo.aggregate(Ezagent.Entity.MagicLinkToken, :count) == before + 1
  end
end
