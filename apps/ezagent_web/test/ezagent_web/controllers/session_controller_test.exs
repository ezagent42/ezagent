defmodule EzagentWeb.SessionControllerTest do
  use EzagentCore.DataCase
  use Phoenix.ConnTest

  @endpoint EzagentWeb.Endpoint

  describe "GET /login (email+password login page)" do
    # task #87: login is email+password. The handle/URI form is removed.
    test "renders the branded email+password form" do
      conn = build_conn() |> get("/login")
      body = html_response(conn, 200)
      assert body =~ "ezagent"
      assert body =~ "Sign in"
      assert body =~ ~s(name="email")
      assert body =~ ~s(name="password")
      assert body =~ ~s(action="/login")
      # handle/URI login removed
      refute body =~ ~s(name="entity_uri")
      refute body =~ ~s(name="secret")
    end

    # task #87 (Allen): magic-link is hidden when SMTP is unconfigured (the
    # test DB has no smtp_config), so the page offers email+password only.
    test "magic-link option hidden when SMTP not configured" do
      conn = build_conn() |> get("/login")
      body = html_response(conn, 200)
      refute body =~ ~s(action="/login/magic")
    end

    test "invalid identity state is cleared from both authentication slots" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "not-a-uri",
          "current_workspace_uri" => "workspace://system"
        })
        |> get("/login")

      assert html_response(conn, 200) =~ "Sign in"
      refute Plug.Conn.get_session(conn, :current_entity_uri)
      refute Plug.Conn.get_session(conn, :current_workspace_uri)
    end

    test "visiting login cannot force logout a valid principal" do
      admin = Ezagent.Entity.User.admin_uri()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => URI.to_string(admin),
          "current_workspace_uri" => "workspace://system"
        })
        |> get("/login")

      assert html_response(conn, 200) =~ "Sign in"
      assert Plug.Conn.get_session(conn, :current_entity_uri) == URI.to_string(admin)
      assert Plug.Conn.get_session(conn, :current_workspace_uri) == "workspace://system"
    end
  end

  describe "POST /login (email+password) — task #87" do
    test "valid email+password → session set + redirect to /sessions" do
      n = System.unique_integer([:positive])
      email = "loginok#{n}@ex.com"
      uri = Ezagent.URI.user("team-alpha", "loginok#{n}")
      {:ok, _} = Ezagent.Users.create(uri, "secret123", [], email_verified: true)

      {:ok, _} =
        Ezagent.Entity.Profile.upsert(%{
          entity_uri: URI.to_string(uri),
          display_name: "L",
          email: email
        })

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login", %{"email" => email, "password" => "secret123"})

      assert redirected_to(conn) == "/login/token"
      assert Plug.Conn.get_session(conn, :current_entity_uri) == URI.to_string(uri)

      delivery = get(recycle(conn), "/login/token")
      body = html_response(delivery, 200)
      assert body =~ ~s(id="one-time-personal-access-token")
      assert body =~ "esr_pat_v1_"
      assert get_resp_header(delivery, "cache-control") == ["no-store"]

      assert redirected_to(get(recycle(delivery), "/login/token")) == "/sessions"

      assert [%Ezagent.Entity.Token{label: "interactive-login"}] =
               Ezagent.Entity.Token.list(uri)
    end

    test "unverified email → generic 'confirm your email', no session (after correct password)" do
      n = System.unique_integer([:positive])
      email = "unv#{n}@ex.com"
      uri = Ezagent.URI.user("team-alpha", "unv#{n}")
      {:ok, _} = Ezagent.Users.create(uri, "secret123", [], email_verified: false)

      {:ok, _} =
        Ezagent.Entity.Profile.upsert(%{
          entity_uri: URI.to_string(uri),
          display_name: "U",
          email: email
        })

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login", %{"email" => email, "password" => "secret123"})

      body = html_response(conn, 200)
      assert body =~ "confirm your email"
      refute Plug.Conn.get_session(conn, :current_entity_uri)
    end

    test "wrong password / unknown email → generic error, no session" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login", %{
          "email" => "nobody#{System.unique_integer([:positive])}@ex.com",
          "password" => "x"
        })

      body = html_response(conn, 200)
      assert body =~ "Invalid email or password"
      refute Plug.Conn.get_session(conn, :current_entity_uri)
    end
  end

  describe "POST /login/magic (passwordless, SMTP-gated) — task #87" do
    test "renders anti-enumeration notice regardless of email" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/magic", %{"email" => "nobody@example.com"})

      body = html_response(conn, 200)
      assert body =~ "If that email can sign in"
    end
  end

  describe "logout" do
    test "DELETE /logout clears session and redirects to /login" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "entity://team-alpha/user/allen"
        })
        |> delete("/logout")

      assert redirected_to(conn) == "/login"
      refute Plug.Conn.get_session(conn, :current_entity_uri)
    end
  end
end
