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
  end

  describe "POST /login/credentials" do
    test "happy path: valid creds → session set + redirect to /sessions" do
      uri = "entity://team-alpha/user/login-happy-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(uri, "right-pw", [])

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/credentials", %{"entity_uri" => uri, "secret" => "right-pw"})

      assert redirected_to(conn) == "/sessions"
      assert Plug.Conn.get_session(conn, :current_entity_uri) == uri
    end

    test "bad password: renders unified page with inline cred error (no redirect)" do
      uri = "entity://team-alpha/user/login-bad-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(uri, "right-pw", [])

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/credentials", %{"entity_uri" => uri, "secret" => "WRONG"})

      # Phase 8c follow-up: render inline (status 200) instead of
      # bouncing through a second redirect. Cookie still empty.
      body = html_response(conn, 200)
      assert body =~ "Invalid URI or credentials."
      refute Plug.Conn.get_session(conn, :current_entity_uri)
    end

    test "unknown user: renders unified page with inline cred error" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/credentials", %{
          "entity_uri" => "entity://team-alpha/user/never-existed",
          "secret" => "x"
        })

      body = html_response(conn, 200)
      assert body =~ "Invalid URI or credentials."
    end

    # Regression: Allen 2026-05-20 (BUG) — bare handle "admin" succeeded
    # auth but the RAW input was put into the session as :current_entity_uri.
    # On the next request RequireEntity called URI.parse("admin") → no
    # scheme → bounced to /login. Login appeared to fail to the user.
    # Fix: store canonical "entity://system/user/admin", not raw "admin".
    test "bare handle stores CANONICAL entity:// URI in session (regression)" do
      handle = "barehandle#{System.unique_integer([:positive])}"
      # Phase 9 PR-2 (SPEC v3 §3): entity URIs carry workspace segment.
      # SPEC #324: tenant login passes explicit workspace param.
      uri = "entity://team-alpha/user/" <> handle
      {:ok, _} = Ezagent.Users.create(uri, "pw", [])

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/credentials", %{
          "entity_uri" => handle,
          "secret" => "pw",
          "workspace" => "team-alpha"
        })

      assert redirected_to(conn) == "/sessions"
      # The critical invariant — NOT the raw handle.
      assert Plug.Conn.get_session(conn, :current_entity_uri) == uri
      refute Plug.Conn.get_session(conn, :current_entity_uri) == handle
    end

    test "bare handle is lowercased before lookup; canonical is stored" do
      # SPEC #324: workspace must be passed explicitly for bare-handle
      # tenant logins (admin login fills it with "system" via the form
      # default).
      uri = "entity://team-alpha/user/admincase#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(uri, "pw", [])

      handle = uri |> String.replace_prefix("entity://team-alpha/user/", "") |> String.upcase()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/credentials", %{
          "entity_uri" => handle,
          "secret" => "pw",
          "workspace" => "team-alpha"
        })

      assert redirected_to(conn) == "/sessions"
      assert Plug.Conn.get_session(conn, :current_entity_uri) == uri
    end

    # Layer 3 of the 2026-05-20 defense-in-depth: ROUND-TRIP. This is
    # the test most directly mirroring Allen's reported experience:
    # bare-handle login succeeded but the next request bounced to
    # /login. None of the controller-only happy-path tests caught it
    # because they stop at the redirect. This test continues:
    # bare-handle POST -> take resulting session -> simulate next
    # request -> assert RequireEntity passes through.
    test "round-trip: bare-handle login → next request passes RequireEntity (regression)" do
      handle = "round#{System.unique_integer([:positive])}"
      # Phase 9 PR-2 (SPEC v3 §3): entity URIs carry workspace segment.
      # SPEC #324 rev 3: bare handles REQUIRE explicit workspace param —
      # no silent default. Test passes it via the form.
      uri = "entity://team-alpha/user/" <> handle
      {:ok, _} = Ezagent.Users.create(uri, "pw", [])

      login_conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/credentials", %{
          "entity_uri" => handle,
          "secret" => "pw",
          "workspace" => "team-alpha"
        })

      # Cross-handler simulation: copy the principal slot the login
      # handler set into a brand-new conn, then drive it through the
      # downstream RequireEntity plug — the exact pipeline a real
      # follow-up request hits.
      principal = Plug.Conn.get_session(login_conn, :current_entity_uri)

      next_conn =
        Phoenix.ConnTest.build_conn(:get, "/sessions")
        |> Plug.Test.init_test_session(%{"current_entity_uri" => principal})
        |> EzagentWeb.Plugs.RequireEntity.call([])

      refute next_conn.halted, "RequireEntity should pass through; saw bounce — login is broken"
      assert next_conn.assigns.current_entity_uri.scheme == "entity"
      assert next_conn.assigns.current_entity_uri.host == "team-alpha"
      assert next_conn.assigns.current_entity_uri.path =~ "/user/"
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

      assert redirected_to(conn) == "/sessions"
      assert Plug.Conn.get_session(conn, :current_entity_uri) == URI.to_string(uri)
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

  describe "POST /login/credentials (legacy handle login — retired in PR-6)" do
    # Regression: Allen 2026-05-20 — bare handle "admin" must be accepted as
    # shortcut for "entity://system/user/admin"; session stores canonical URI.
    test "bare handle: 'foo' → authenticates as entity://team-alpha/user/foo, session stores canonical URI" do
      handle = "barehandle#{System.unique_integer([:positive])}"
      # Phase 9 PR-2 (SPEC v3 §3): entity URIs carry workspace segment.
      # SPEC #324 rev 3: workspace param REQUIRED for bare handles.
      uri = "entity://team-alpha/user/" <> handle
      {:ok, _} = Ezagent.Users.create(uri, "pw", [])

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/credentials", %{
          "entity_uri" => handle,
          "secret" => "pw",
          "workspace" => "team-alpha"
        })

      assert redirected_to(conn) == "/sessions"
      assert Plug.Conn.get_session(conn, :current_entity_uri) == uri
    end

    # Regression: Allen 2026-05-20 — bare handle case-insensitive lowercasing.
    test "bare handle is lowercased before lookup" do
      # SPEC #324 rev 3: workspace REQUIRED for bare handles (no
      # silent default). Test creates a user in team-alpha and passes
      # workspace via form param.
      uri = "entity://team-alpha/user/admincase#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(uri, "pw", [])

      # Compose the mixed-case handle the user might type. Phase 9 PR-2
      # (SPEC v3 §3): canonical URI carries workspace segment.
      handle = uri |> String.replace_prefix("entity://team-alpha/user/", "") |> String.upcase()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/login/credentials", %{
          "entity_uri" => handle,
          "secret" => "pw",
          "workspace" => "team-alpha"
        })

      assert redirected_to(conn) == "/sessions"
      assert Plug.Conn.get_session(conn, :current_entity_uri) == uri
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
