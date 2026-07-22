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
      # PR-J — to exercise the empty-sessions branch, terminate every
      # session currently registered under the SessionSupervisor via
      # `DynamicSupervisor.terminate_child/2` (plain `GenServer.stop`
      # would trigger the default `:permanent` restart). Sessions then
      # disappear from `EzagentDomainInstanceMessage.list_sessions/0`.
      restore_short_names = drain_system_sessions()

      on_exit(fn ->
        # Restore only the boot baseline. Other live system sessions are
        # residue from earlier tests in this shared VM and must not be
        # recreated here (doing so made teardown scale with the whole suite
        # and eventually outlive the SQL sandbox ownership timeout).
        for short <- restore_short_names do
          # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A —
          # return is `{:ok, uri, meta} | {:error, _}`. This re-seed
          # discards everything; we only need the side effect.
          _ =
            create_session_via_workspace(short, Ezagent.Entity.User.admin_uri(),
              template_name: "default"
            )
        end
      end)

      :ok
    end

    # #189 full-suite session-creation-under-load flake (family:
    # #902/#58/AutoserviceTier1Seed). The shared `setup` above registers an
    # `on_exit` that re-seeds torn-down sessions via
    # `Ezagent.Workspace.create_session/3` — a heavy SYNCHRONOUS op (Session
    # Kind spawn + template freeze/finalize + a `:global` per-URI lock), NOT a
    # self-deadlock (green in isolation; the create path never re-enters the
    # busy Workspace Kind). Under the full concurrent mac-runner load this
    # teardown can exceed ExUnit's default 60s on_exit budget. Raise the budget
    # (a timeout quarantine, not a logic change). Both tests in this describe
    # share the same slow on_exit, so both carry the tag.
    @tag timeout: 180_000
    test "renders the wizard when no sessions exist", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "entity://system/user/admin"
        })

      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Welcome to ezagent"
      assert html =~ "first-session-wizard"
      assert html =~ ~s(name="wizard[short_name]")
      assert html =~ "main"
    end

    # #189 flake (see above) — the shared on_exit re-seed can also blow the
    # default 60s on_exit budget here under full concurrent mac-runner load.
    @tag timeout: 180_000
    test "submitting the wizard creates the session and navigates to /sessions", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "entity://system/user/admin"
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      # Submitting the form triggers `push_navigate(/sessions)`.
      # `render_submit/1` returns the redirect tuple in :error form.
      assert {:error, {:live_redirect, %{to: "/sessions"}}} =
               lv
               |> form("#first-session-wizard", %{"wizard" => %{"short_name" => "main"}})
               |> render_submit()

      # session://system/default/main is now registered.
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(URI.new!("session://system/default/main"))
      # …and bound to the default workspace (invariant).
      assert {:ok, _workspace_uri} =
               Ezagent.WorkspaceRegistry.lookup(URI.new!("session://system/default/main"))
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

  # Terminate every SYSTEM-workspace session under EzagentDomainInstanceMessage.SessionSupervisor so
  # the wizard's empty-list branch can be exercised. Returns the list of
  # session short_names that were torn down (so `on_exit` can re-seed).
  # Drive `EzagentDomainInstanceMessage.list_sessions/0` to empty so HomeLive takes
  # the wizard branch.
  #
  # `list_sessions/0` derives its result from `Ezagent.KindRegistry`
  # (every live `session://` Kind), NOT from the membership of any one
  # supervisor. The boot-seeded `session://system/default/main` is in
  # fact a `:permanent` child of the GENERIC `Ezagent.KindSupervisor`
  # (the `resolve_supervisor/1` fallback), NOT
  # `EzagentDomainInstanceMessage.SessionSupervisor` — so the old drain, which
  # only walked `SessionSupervisor`'s children, found nothing to
  # terminate and the wizard branch never fired.
  #
  # Drain from the registry instead: enumerate live `session://system/...`
  # Kind, and `DynamicSupervisor.terminate_child/2` each one against its
  # ACTUAL parent supervisor (resolved from the process's `$ancestors`).
  # `terminate_child` is the only call that permanently removes a
  # `:permanent` child — a bare `Process.exit`/`GenServer.stop` would
  # trigger the supervisor restart and the session would reappear.
  # The HomeLive landing check is workspace-scoped, so other tenants are
  # deliberately left untouched. Return only the canonical boot session's
  # short name for restoration; transient test sessions are cleanup residue,
  # not shared fixtures. The old implementation returned `uri.host` for every
  # session ("system"), then synchronously recreated it N times at on_exit.
  defp drain_system_sessions do
    live_sessions =
      Ezagent.KindRegistry.list_all()
      |> Enum.filter(fn {uri, pid} ->
        is_binary(uri) and String.starts_with?(uri, "session://system/") and is_pid(pid)
      end)

    restore_short_names =
      if Enum.any?(live_sessions, fn {uri_str, _pid} ->
           uri_str == "session://system/default/main"
         end) do
        ["main"]
      else
        []
      end

    for {_uri_str, pid} <- live_sessions do
      case parent_supervisor(pid) do
        nil -> :ok
        sup -> DynamicSupervisor.terminate_child(sup, pid)
      end
    end

    wait_until_system_empty()
    restore_short_names
  end

  # The parent DynamicSupervisor of a Kind.Server pid is the first entry
  # of its `$ancestors` process-dict key (set by `proc_lib` on spawn).
  defp parent_supervisor(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :"$ancestors") do
          [parent | _] when is_atom(parent) -> Process.whereis(parent)
          [parent | _] when is_pid(parent) -> parent
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp wait_until_system_empty(retries \\ 50)
  defp wait_until_system_empty(0), do: :ok

  defp wait_until_system_empty(retries) do
    if Enum.any?(Ezagent.KindRegistry.list_all(), fn {uri, _pid} ->
         String.starts_with?(uri, "session://system/")
       end) do
      Process.sleep(20)
      wait_until_system_empty(retries - 1)
    else
      :ok
    end
  end
end
