defmodule EzagentWeb.RegistrationControllerTest do
  use EzagentWeb.ConnCase

  alias Ezagent.AppSettings
  alias Ezagent.Entity.{InviteCode, MagicLinkToken, Profile, RegistrationRequest}
  alias Ezagent.Users

  describe "GET /register gate (task #87)" do
    test "closed by default → shows request-access and invite paths", %{conn: conn} do
      body = conn |> get("/register") |> html_response(200)
      assert body =~ "Registration is currently closed"
      assert body =~ ~s(id="registration-request-form")
      assert body =~ ~s(id="invite-registration-form")
    end

    test "a valid invite deep link opens the registration form while public registration is closed",
         %{conn: conn} do
      code = mint_invite()

      body = conn |> get("/register?invite=#{URI.encode_www_form(code)}") |> html_response(200)
      assert body =~ ~s(name="email")
      assert body =~ ~s(value="#{code}")
      assert body =~ "readonly"
    end

    test "an invalid invite deep link stays closed with an actionable error", %{conn: conn} do
      body = conn |> get("/register?invite=invalid") |> html_response(200)
      assert body =~ "Registration is currently closed"
      assert body =~ "invite code is not valid"
    end

    test "open → shows the email+password form", %{conn: conn} do
      AppSettings.put("registration_open", true)
      body = conn |> get("/register") |> html_response(200)
      assert body =~ ~s(name="email")
      assert body =~ ~s(name="password")
      assert body =~ ~s(name="display_name")
    end

    test "open + require_invite → form shows the invite-code field", %{conn: conn} do
      AppSettings.put("registration_open", true)
      AppSettings.put("registration_require_invite", true)
      body = conn |> get("/register") |> html_response(200)
      assert body =~ ~s(name="invite_code")
    end
  end

  describe "POST /register/request" do
    test "stores a normalized pending request and returns a uniform receipt", %{conn: conn} do
      body =
        conn
        |> post("/register/request", %{"email" => "  Buyer@Example.com "})
        |> html_response(200)

      assert body =~ "Request received"

      assert Enum.any?(RegistrationRequest.list_pending(), fn request ->
               request.email == "buyer@example.com"
             end)
    end
  end

  describe "POST /register (task #87)" do
    test "closed → refused with the closed notice (no user created)", %{conn: conn} do
      body =
        conn
        |> post("/register", %{
          "email" => "x@ex.com",
          "password" => "secret123",
          "display_name" => "X"
        })
        |> html_response(200)

      assert body =~ "Registration is currently closed"
      assert Profile.by_email("x@ex.com") == nil
    end

    test "open + invite: valid code → check-your-email + unverified user created", %{conn: conn} do
      AppSettings.put("registration_open", true)
      AppSettings.put("registration_require_invite", true)

      code = mint_invite()

      email = "reg#{System.unique_integer([:positive])}@ex.com"

      body =
        conn
        |> post("/register", %{
          "email" => email,
          "password" => "secret123",
          "display_name" => "Reg",
          "invite_code" => code
        })
        |> html_response(200)

      assert body =~ "Check your email"
      uri = Profile.by_email(email).entity_uri
      assert Users.get_by_uri(uri).email_verified == false
    end

    test "open + invite: missing code → 'invite code is required'", %{conn: conn} do
      AppSettings.put("registration_open", true)
      AppSettings.put("registration_require_invite", true)

      body =
        conn
        |> post("/register", %{
          "email" => "y@ex.com",
          "password" => "secret123",
          "display_name" => "Y"
        })
        |> html_response(200)

      assert body =~ "invite code is required"
      assert Profile.by_email("y@ex.com") == nil
    end
  end

  describe "GET /auth/confirm/:token (task #87)" do
    test "valid confirm token flips email_verified and redirects to /login", %{conn: conn} do
      AppSettings.put("registration_open", true)
      AppSettings.put("registration_require_invite", true)

      code = mint_invite()

      email = "conf#{System.unique_integer([:positive])}@ex.com"

      {:ok, uri} =
        Ezagent.Registration.register_with_password(email, "secret123", "Conf", invite_code: code)

      refute Users.get_by_uri(uri).email_verified
      {:ok, token} = MagicLinkToken.mint(email, purpose: "confirm")

      conn = get(conn, "/auth/confirm/#{token}")
      assert redirected_to(conn) == "/login"
      assert Users.get_by_uri(uri).email_verified == true
    end

    test "invalid confirm token → /login with error", %{conn: conn} do
      conn = get(conn, "/auth/confirm/bogus")
      assert redirected_to(conn) == "/login"
    end
  end

  defp mint_invite do
    suffix = System.unique_integer([:positive])
    workspace_name = "registration-controller-#{suffix}"
    admin_uri = Ezagent.Entity.User.admin_uri()

    {:ok, _workspace_pid} =
      Ezagent.Workspace.create(workspace_name, %{
        created_by: admin_uri
      })

    workspace_uri = Ezagent.URI.workspace(workspace_name)

    {:ok, {code, _invite}} =
      InviteCode.mint(%{
        workspace_uri: URI.to_string(workspace_uri),
        created_by: URI.to_string(admin_uri)
      })

    code
  end
end
