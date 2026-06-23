defmodule EzagentWeb.HomeLiveTest do
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  defp create_session_via_workspace(short_name, creator_uri, opts) do
    template_name = Keyword.fetch!(opts, :template_name)

    workspace_uri =
      Keyword.get(opts, :workspace_uri, Ezagent.Capability.workspace_of(creator_uri))

    ensure_workspace_seeded!(workspace_uri)

    with {:ok, result} <-
           Ezagent.Workspace.create_session(
             workspace_uri,
             %{short_name: short_name, template_name: template_name},
             %{caller: creator_uri, caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])}
           ) do
      {:ok, result.session_uri, %{}}
    end
  end

  test "GET / unauthenticated redirects to /login", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  test "GET / with session AND existing sessions redirects to /sessions", %{conn: conn} do
    # The chat Application's `:test`-env seed populates `session://system/default/main`
    # at boot, so `list_sessions/0` returns non-empty by default in the
    # web test suite. Verify the redirect path under that condition.
    assert EzagentDomainInstanceMessage.list_sessions() != []

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => "entity://system/user/admin"
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
      torn_down = drain_sessions()

      on_exit(fn ->
        # Re-seed any session we terminated so this test file's teardown
        # doesn't poison subsequent test files (most of which assume
        # `session://system/default/main` alive at boot).
        for short <- torn_down do
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

  # Terminate every session under EzagentDomainInstanceMessage.SessionSupervisor so
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
  # Drain from the registry instead: enumerate every live `session://`
  # Kind, and `DynamicSupervisor.terminate_child/2` each one against its
  # ACTUAL parent supervisor (resolved from the process's `$ancestors`).
  # `terminate_child` is the only call that permanently removes a
  # `:permanent` child — a bare `Process.exit`/`GenServer.stop` would
  # trigger the supervisor restart and the session would reappear.
  defp drain_sessions do
    live_sessions =
      Ezagent.KindRegistry.list_all()
      |> Enum.filter(fn {uri, pid} ->
        is_binary(uri) and String.starts_with?(uri, "session://") and is_pid(pid)
      end)

    shorts = Enum.map(live_sessions, fn {uri_str, _pid} -> URI.new!(uri_str).host end)

    for {_uri_str, pid} <- live_sessions do
      case parent_supervisor(pid) do
        nil -> :ok
        sup -> DynamicSupervisor.terminate_child(sup, pid)
      end
    end

    wait_until_empty()
    shorts
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

  defp wait_until_empty(retries \\ 50)
  defp wait_until_empty(0), do: :ok

  defp wait_until_empty(retries) do
    if Enum.any?(Ezagent.KindRegistry.list_all(), fn {uri, _pid} ->
         String.starts_with?(uri, "session://")
       end) do
      Process.sleep(20)
      wait_until_empty(retries - 1)
    else
      :ok
    end
  end
end
