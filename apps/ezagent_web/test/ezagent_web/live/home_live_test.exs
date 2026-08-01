defmodule EzagentWeb.HomeLiveTest do
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  defp create_session_via_workspace(short_name, creator_uri, opts) do
    template_name = Keyword.fetch!(opts, :template_name)

    workspace_uri =
      Keyword.get(opts, :workspace_uri, Ezagent.Capability.workspace_of(creator_uri))

    ensure_workspace_seeded!(workspace_uri)
    target = Ezagent.URI.with_action(workspace_uri, :workspace, :create_session)
    admin = Ezagent.Entity.User.admin_uri()
    {:ok, create_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, creator_uri, target)

    with {:ok, result} <-
           Ezagent.Workspace.create_session(
             workspace_uri,
             %{short_name: short_name, template_name: template_name},
             %{
               caller: creator_uri,
               authenticated_principal: creator_uri,
               caps: MapSet.new([create_cap])
             }
           ) do
      {:ok, result.session_uri, %{}}
    end
  end

  test "GET / unauthenticated redirects to /login", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  describe "GET / with invalid identity input" do
    test "fails closed for a malformed URI", %{conn: conn} do
      assert_invalid_identity_redirect(conn, "not-a-uri", "malformed-cookie")
    end

    test "fails closed for a non-entity URI", %{conn: conn} do
      assert_invalid_identity_redirect(conn, "workspace://system", "non-entity-cookie")
    end

    test "fails closed for an entity URI whose principal no longer exists", %{conn: conn} do
      missing_uri = "entity://auth-fail/user/missing-principal"
      assert Ezagent.Users.get_by_uri(missing_uri) == nil

      assert_invalid_identity_redirect(conn, missing_uri, "missing-principal")
    end
  end

  test "GET / with session AND existing sessions redirects to /sessions", %{conn: conn} do
    # Create a session through the real workspace path so the authenticated
    # admin holds the born-signed owner member-cap. A merely live global boot
    # session is no longer sufficient: unified authorization intentionally
    # hides sessions for which the caller has no current entitlement.
    {:ok, _session_uri, %{}} =
      create_session_via_workspace(
        "home-existing-#{System.unique_integer([:positive])}",
        Ezagent.Entity.User.admin_uri(),
        template_name: "default"
      )

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => "entity://system/user/admin"
      })

    assert {:error, {:live_redirect, %{to: "/sessions"}}} = live(conn, ~p"/")
  end

  # W0 tenant-isolation regression. The landing判据 must be scoped to the
  # CALLER's workspace, not the global registry. Here tenant-`w0iso`'s
  # workspace owns ZERO sessions while the boot-seeded
  # `session://system/default/main` lives in the DISTINCT `system`
  # workspace. A tenant-`w0iso` operator must land on the WIZARD — never be
  # bounced to `/sessions` (which would both mis-land them AND leak the
  # existence of another tenant's session).
  #
  # On the OLD global `list_sessions/0` code this test FAILS: the system
  # seed makes the global list non-empty → `{:error, {:live_redirect, ...}}`
  # → the `{:ok, _lv, html}` match raises.
  test "GET / scopes the landing judgment to the caller's workspace (no cross-tenant leak)",
       %{conn: conn} do
    caller_uri = URI.new!("entity://w0iso/user/alice")
    assert {:ok, _user} = Ezagent.Users.create_read_only(caller_uri)

    # Precondition: some OTHER tenant (system) has a live session.
    assert Enum.any?(EzagentDomainInstanceMessage.list_sessions(), fn uri ->
             match?(%URI{scheme: "session", host: "system"}, uri)
           end)

    # …but the caller's own workspace (tenant `w0iso`) has none.
    assert [] =
             EzagentDomainInstanceMessage.list_sessions(URI.new!("workspace://w0iso"))

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(caller_uri)
      })

    # No redirect → wizard rendered inline (a redirect would return
    # `{:error, {:live_redirect, ...}}` and fail this match).
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "first-session-wizard"
    assert html =~ "Welcome to ezagent"
  end

  # W0 — the landing scope PREFERS the session's selected
  # `current_workspace_uri` over the entity's home workspace, so a system
  # member who context-switched into an empty tenant lands on the wizard
  # (matching what `/sessions` renders — §6.5/§13.2) even though their home
  # `system` workspace owns the boot-seeded `main`.
  test "GET / prefers the selected current_workspace_uri over the entity home workspace",
       %{conn: conn} do
    # Home workspace (system) HAS a session…
    assert Enum.any?(EzagentDomainInstanceMessage.list_sessions(), fn uri ->
             match?(%URI{scheme: "session", host: "system"}, uri)
           end)

    # …but the SELECTED workspace (w0iso) has none.
    assert [] = EzagentDomainInstanceMessage.list_sessions(URI.new!("workspace://w0iso"))

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => "entity://system/user/admin",
        "current_workspace_uri" => "workspace://w0iso"
      })

    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "first-session-wizard"
  end

  # W0 — a malformed/non-workspace selected slot must not crash the mount;
  # it falls back to the entity's home workspace (fail-safe). Here the
  # fallback (system) has the boot-seeded session → redirect.
  test "GET / tolerates a malformed current_workspace_uri (falls back to entity home)",
       %{conn: conn} do
    short_name = "malformed-fallback-#{System.unique_integer([:positive])}"

    assert {:ok, fallback_session, %{}} =
             create_session_via_workspace(short_name, Ezagent.Entity.User.admin_uri(),
               template_name: "default"
             )

    on_exit(fn -> Ezagent.Kind.terminate(fallback_session) end)

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => "entity://system/user/admin",
        "current_workspace_uri" => "@@not-a-uri@@"
      })

    assert {:error, {:live_redirect, %{to: "/sessions"}}} = live(conn, ~p"/")
  end

  describe "wizard (no sessions)" do
    setup do
      workspace_name = "home-wizard-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.workspace(workspace_name)
      ensure_workspace_seeded!(workspace_uri)

      on_exit(fn -> _ = Ezagent.Kind.terminate(workspace_uri) end)

      %{workspace_uri: workspace_uri}
    end

    # Use a private workspace so "empty" means no live OR durable sessions
    # without tearing down the shared system fixture.
    test "renders the wizard when no sessions exist", %{conn: conn, workspace_uri: workspace_uri} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "entity://system/user/admin",
          "current_workspace_uri" => URI.to_string(workspace_uri)
        })

      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Welcome to ezagent"
      assert html =~ "first-session-wizard"
      assert html =~ ~s(name="wizard[short_name]")
      assert html =~ "main"
    end

    test "submitting the wizard creates the session and navigates to /sessions", %{
      conn: conn,
      workspace_uri: workspace_uri
    } do
      short_name = "wizard-submit-#{System.unique_integer([:positive])}"

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "entity://system/user/admin",
          "current_workspace_uri" => URI.to_string(workspace_uri)
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      # Submitting the form triggers `push_navigate(/sessions)`.
      # `render_submit/1` returns the redirect tuple in :error form.
      assert {:error, {:live_redirect, %{to: "/sessions"}}} =
               lv
               |> form("#first-session-wizard", %{"wizard" => %{"short_name" => short_name}})
               |> render_submit()

      session_uri = Ezagent.URI.session(:system, :default, short_name)
      on_exit(fn -> _ = Ezagent.Kind.terminate(session_uri) end)
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
      # The wizard intentionally creates in the admin's structural home workspace.
      assert {:ok, %URI{scheme: "workspace", host: "system"}} =
               Ezagent.WorkspaceRegistry.lookup(session_uri)
    end
  end

  defp ensure_workspace_seeded!(%URI{scheme: "workspace", host: name})
       when is_binary(name) and name != "" do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        case Ezagent.Workspace.create(name, %{}) do
          {:ok, _pid} -> :ok
          {:error, :workspace_exists} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to seed workspace #{name}: #{inspect(reason)}"
        end

      _ ->
        :ok
    end
  end

  defp assert_invalid_identity_redirect(conn, identity, session_name) do
    workspace_uri = URI.new!("workspace://auth-fail")
    sessions_before = EzagentDomainInstanceMessage.list_sessions(workspace_uri)

    conn =
      Plug.Test.init_test_session(conn, %{
        "current_entity_uri" => identity,
        "current_workspace_uri" => URI.to_string(workspace_uri)
      })

    trace_session_creation_calls(fn ->
      assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end)

    assert EzagentDomainInstanceMessage.list_sessions(workspace_uri) == sessions_before

    assert :error =
             Ezagent.KindRegistry.lookup(URI.new!("session://auth-fail/default/#{session_name}"))
  end

  defp trace_session_creation_calls(fun) do
    mfa = {Ezagent.Workspace, :create_session, 3}
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    try do
      fun.()
      refute_receive {:trace, _pid, :call, {Ezagent.Workspace, :create_session, _args}}, 50
    after
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern(mfa, false, [:local])
    end
  end
end
