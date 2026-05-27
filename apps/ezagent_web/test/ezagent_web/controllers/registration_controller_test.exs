defmodule EzagentWeb.RegistrationControllerTest do
  use EzagentWeb.ConnCase

  # String session key — get_session/2 looks keys up as strings; an
  # atom key here would simply not be found.
  # PR-B 2026-05-24: `pending_workspace` is now also required — the
  # onboarding step sets it before /register/complete is reached.
  # Codex round-1 HIGH-2: /register/complete revalidates that the
  # workspace still accepts the email; helper ensures a matching rule
  # exists so the test's irreversible write isn't blocked.
  defp pending_conn(conn, email, workspace \\ "team-alpha") do
    # SPEC #335 (PR #335) renamed the seed workspace `default → system`
    # AND deleted all silent "default" fallbacks. Tests now use
    # `team-alpha` as the generic non-system test workspace — matches
    # the assertion shape `entity://user/team-alpha/<handle>`.
    ensure_rule(workspace, email)

    Plug.Test.init_test_session(conn, %{
      "pending_registration_email" => email,
      "pending_workspace" => workspace
    })
  end

  defp ensure_rule(workspace_name, email) do
    # Create the workspace if missing, add a user_list rule for the
    # email so workspace_still_valid?/2 returns true.
    _ = Ezagent.Workspace.create(workspace_name, %{})

    _ =
      Ezagent.Workspace.add_magic_link_rule("workspace://" <> workspace_name, "user_list", email)

    :ok
  end

  test "GET /register/complete shows the form prefilled with a derived slug", %{conn: conn} do
    conn = conn |> pending_conn("allen.woods@good.com") |> get("/register/complete")
    assert html_response(conn, 200) =~ "allen-woods"
  end

  test "GET /register/complete without a pending email redirects to /login", %{conn: conn} do
    conn = get(conn, "/register/complete")
    assert redirected_to(conn) == "/login"
  end

  test "GET /register/complete without a workspace bounces to onboarding (PR-B)", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{"pending_registration_email" => "noworkspace@good.com"})
      |> get("/register/complete")

    assert redirected_to(conn) == "/onboarding/workspace"
  end

  test "POST /register/complete creates the principal and logs in", %{conn: conn} do
    conn =
      conn
      |> pending_conn("newbie@good.com")
      |> post("/register/complete", %{"handle" => "newbie", "display_name" => "New Bie"})

    assert redirected_to(conn) == "/sessions"
    assert get_session(conn, :current_entity_uri) == "entity://user/team-alpha/newbie"
    assert get_session(conn, :pending_registration_email) == nil

    assert Ezagent.Entity.Profile.by_email("newbie@good.com").entity_uri ==
             "entity://user/team-alpha/newbie"
  end

  test "POST /register/complete in a CUSTOM workspace creates entity://user/<ws>/<slug>", %{
    conn: conn
  } do
    # PR-B 2026-05-24 — the workspace from onboarding is honored.
    conn =
      conn
      |> pending_conn("alice@acme.test", "acme")
      |> post("/register/complete", %{"handle" => "alice", "display_name" => "Alice"})

    assert redirected_to(conn) == "/sessions"
    assert get_session(conn, :current_entity_uri) == "entity://user/acme/alice"
  end

  test "POST with a taken handle re-renders the form with a suggestion", %{conn: conn} do
    {:ok, _} = Ezagent.Users.create("entity://user/team-alpha/taken", nil, [])

    conn =
      conn
      |> pending_conn("taken@good.com")
      |> post("/register/complete", %{"handle" => "taken", "display_name" => "T"})

    assert html_response(conn, 200) =~ "taken-2"
  end
end
