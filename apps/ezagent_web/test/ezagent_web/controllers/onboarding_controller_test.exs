defmodule EzagentWeb.OnboardingControllerTest do
  @moduledoc """
  PR-B 2026-05-24 (Allen, SPEC v2) — workspace onboarding page.

  Reached after MagicLinkController verified the email + the email
  has NO existing principal. User picks an existing workspace to
  join (matched by magic_link_rule) OR creates a new one
  (OQ-V2-1 Option A — non-admin self-serve allowed).
  """

  use EzagentWeb.ConnCase

  alias Ezagent.Workspace.MagicLinkRule

  defp pending_email(conn, email) do
    Plug.Test.init_test_session(conn, %{"pending_registration_email" => email})
  end

  defp uniq, do: System.unique_integer([:positive])

  describe "GET /onboarding/workspace" do
    test "renders the picker for a pending email", %{conn: conn} do
      conn = conn |> pending_email("alice@acme.test") |> get("/onboarding/workspace")
      body = html_response(conn, 200)
      assert body =~ "Pick a workspace"
      assert body =~ "alice@acme.test"
      assert body =~ "Join existing"
      assert body =~ "Or create new"
    end

    test "redirects to /login without a pending email", %{conn: conn} do
      assert conn |> get("/onboarding/workspace") |> redirected_to() == "/login"
    end
  end

  describe "POST /onboarding/workspace — join existing" do
    test "rejects when workspace's rules don't accept the email", %{conn: conn} do
      ws_name = "private-#{uniq()}"
      {:ok, _} = Ezagent.Workspace.create(ws_name, %{})
      {:ok, _} = MagicLinkRule.add("workspace://" <> ws_name, "domain", "elsewhere.test")

      conn =
        conn
        |> pending_email("alice@acme.test")
        |> post("/onboarding/workspace", %{
          "action" => "join",
          "workspace_name" => ws_name
        })

      body = html_response(conn, 200)
      assert body =~ "does not accept your email"
    end

    test "succeeds + sets :pending_workspace when rules accept", %{conn: conn} do
      ws_name = "joinable-#{uniq()}"
      {:ok, _} = Ezagent.Workspace.create(ws_name, %{})
      {:ok, _} = MagicLinkRule.add("workspace://" <> ws_name, "domain", "acme.test")

      conn =
        conn
        |> pending_email("alice@acme.test")
        |> post("/onboarding/workspace", %{
          "action" => "join",
          "workspace_name" => ws_name
        })

      assert redirected_to(conn) == "/register/complete"
      assert get_session(conn, :pending_workspace) == ws_name
    end
  end

  describe "POST /onboarding/workspace — create new" do
    test "creates the workspace + adds the chosen rule + redirects", %{conn: conn} do
      ws_name = "newco-#{uniq()}"

      conn =
        conn
        |> pending_email("admin@newco.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => ws_name,
          "rule_type" => "domain"
        })

      assert redirected_to(conn) == "/register/complete"
      assert get_session(conn, :pending_workspace) == ws_name

      # Workspace + rule landed
      assert Ezagent.Workspace.list_visible() |> Enum.any?(&(&1.name == ws_name))

      assert Ezagent.Workspace.accepts_email?("workspace://" <> ws_name, "admin@newco.test")
    end

    test "rejects invalid rule_type", %{conn: conn} do
      conn =
        conn
        |> pending_email("a@b.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => "newco-x-#{uniq()}",
          "rule_type" => "wat"
        })

      body = html_response(conn, 200)
      assert body =~ "Invalid rule type"
    end
  end

  describe "security — codex PR-B round-1 fixes" do
    test "CRITICAL: cannot hijack an existing workspace via 'create new'", %{conn: conn} do
      # Pre-fix: submitting workspace_name=existing-workspace would treat
      # the unique-conflict error from Workspace.create as :ok, then add
      # the attacker's rule + join. Especially dangerous for `system`.
      ws_name = "hijack-target-#{uniq()}"
      {:ok, _} = Ezagent.Workspace.create(ws_name, %{})

      conn =
        conn
        |> pending_email("attacker@evil.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => ws_name,
          "rule_type" => "domain"
        })

      body = html_response(conn, 200)
      assert body =~ "already exists"

      # No rule was added — attacker is not in.
      refute Ezagent.Workspace.accepts_email?("workspace://" <> ws_name, "attacker@evil.test")

      # No pending_workspace set
      refute get_session(conn, :pending_workspace) == ws_name
    end

    test "CRITICAL: cannot create 'system' workspace (reserved name)", %{conn: conn} do
      conn =
        conn
        |> pending_email("attacker@evil.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => "system",
          "rule_type" => "domain"
        })

      body = html_response(conn, 200)
      assert body =~ "reserved"
    end

    test "CRITICAL: cannot create 'admin' workspace (reserved name)", %{conn: conn} do
      conn =
        conn
        |> pending_email("attacker@evil.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => "admin",
          "rule_type" => "domain"
        })

      assert html_response(conn, 200) =~ "reserved"
    end

    test "HIGH-1: rejects workspace names with slashes (URI injection)", %{conn: conn} do
      conn =
        conn
        |> pending_email("alice@x.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => "foo/bar",
          "rule_type" => "domain"
        })

      body = html_response(conn, 200)
      assert body =~ "lowercase letters, digits, and hyphens"
    end

    test "HIGH-1: rejects workspace names with spaces", %{conn: conn} do
      conn =
        conn
        |> pending_email("alice@x.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => "my company",
          "rule_type" => "domain"
        })

      assert html_response(conn, 200) =~ "lowercase letters, digits, and hyphens"
    end

    test "HIGH-1: rejects too-short workspace name", %{conn: conn} do
      conn =
        conn
        |> pending_email("alice@x.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => "x",
          "rule_type" => "domain"
        })

      assert html_response(conn, 200) =~ "too short"
    end

    test "MEDIUM: cannot create more than one workspace per pending registration", %{conn: conn} do
      # First create succeeds
      ws1 = "first-#{uniq()}"

      conn =
        conn
        |> pending_email("flooder@evil.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => ws1,
          "rule_type" => "domain"
        })

      assert redirected_to(conn) == "/register/complete"
      assert get_session(conn, :pending_workspace) == ws1

      # Second create attempt (within same session) rejected
      conn2 =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{
          "pending_registration_email" => "flooder@evil.test",
          "pending_workspace" => ws1
        })
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => "second-#{uniq()}",
          "rule_type" => "domain"
        })

      body = html_response(conn2, 200)
      assert body =~ "already picked a workspace"
    end

    test "uppercase + leading/trailing whitespace canonicalized to lowercase slug", %{conn: conn} do
      ws_name = "Canon-Test-#{uniq()}"

      conn =
        conn
        |> pending_email("user@x.test")
        |> post("/onboarding/workspace", %{
          "action" => "create",
          "workspace_name" => "  #{ws_name}  ",
          "rule_type" => "domain"
        })

      expected = String.downcase(ws_name)
      assert get_session(conn, :pending_workspace) == expected
    end
  end
end
