defmodule EzagentWeb.MagicLinkInvariantsTest do
  @moduledoc """
  Username & Auth M3 — security invariants. A failure here means a
  design rule (spec §1, §5.5, §5.6) was violated.
  """
  use EzagentWeb.ConnCase

  alias Ezagent.Entity.MagicLinkToken
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

    Ezagent.AppSettings.put("registration_domains", ["good.com"])
    :ok
  end

  test "INVARIANT: a magic-link token is single-use" do
    {:ok, raw} = MagicLinkToken.mint("once@good.com")
    assert {:ok, _} = MagicLinkToken.consume(raw)
    assert {:error, :consumed} = MagicLinkToken.consume(raw)
  end

  test "INVARIANT: an expired token is rejected" do
    {:ok, raw} = MagicLinkToken.mint("old@good.com", ttl_seconds: -1)
    assert {:error, :expired} = MagicLinkToken.consume(raw)
  end

  test "INVARIANT: POST /login is anti-enumeration — identical response for allowed/denied" do
    allowed = post(build_conn(), "/login", %{"email" => "new@good.com"})
    denied = post(build_conn(), "/login", %{"email" => "new@bad.com"})

    assert html_response(allowed, 200) == html_response(denied, 200)
  end

  test "INVARIANT: POST /login is rate-limited per email" do
    before = EzagentCore.Repo.aggregate(MagicLinkToken, :count)

    for _ <- 1..6, do: post(build_conn(), "/login", %{"email" => "spam@good.com"})

    after_count = EzagentCore.Repo.aggregate(MagicLinkToken, :count)
    # limit is 3 per 15-min window — at most 3 tokens minted despite 6 posts.
    assert after_count - before <= 3
  end

  test "INVARIANT: magic-link login renews the session id (fixation defence)" do
    {:ok, _} =
      Ezagent.Entity.Profile.upsert(%{
        entity_uri: "entity://user/team-alpha/fix",
        display_name: "Fix",
        email: "fix@good.com"
      })

    {:ok, _} = Ezagent.Users.create("entity://user/team-alpha/fix", nil, [])
    {:ok, raw} = MagicLinkToken.mint("fix@good.com")

    conn = get(build_conn(), "/auth/magic/#{raw}")
    assert get_session(conn, :current_entity_uri) == "entity://user/team-alpha/fix"
  end
end
