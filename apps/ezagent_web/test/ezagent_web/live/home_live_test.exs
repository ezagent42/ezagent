defmodule EzagentWeb.HomeLiveTest do
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / unauthenticated redirects to /login", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  test "GET / with session AND existing sessions redirects to /sessions", %{conn: conn} do
    # The chat Application's `:test`-env seed populates `session://default/system/main`
    # at boot, so `list_sessions/0` returns non-empty by default in the
    # web test suite. Verify the redirect path under that condition.
    assert EzagentDomainChat.list_sessions() != []

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => "entity://user/system/admin"
      })

    assert {:error, {:live_redirect, %{to: "/sessions"}}} = live(conn, ~p"/")
  end

  describe "wizard (no sessions)" do
    setup do
      # PR-J — to exercise the empty-sessions branch, terminate every
      # session currently registered under the SessionSupervisor via
      # `DynamicSupervisor.terminate_child/2` (plain `GenServer.stop`
      # would trigger the default `:permanent` restart). Sessions then
      # disappear from `EzagentDomainChat.list_sessions/0`.
      torn_down = drain_sessions()

      on_exit(fn ->
        # Re-seed any session we terminated so this test file's teardown
        # doesn't poison subsequent test files (most of which assume
        # `session://default/system/main` alive at boot).
        for short <- torn_down do
          EzagentDomainChat.create_session(short, Ezagent.Entity.User.admin_uri())
        end
      end)

      :ok
    end

    test "renders the wizard when no sessions exist", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => "entity://user/system/admin"
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
          "current_entity_uri" => "entity://user/system/admin"
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      # Submitting the form triggers `push_navigate(/sessions)`.
      # `render_submit/1` returns the redirect tuple in :error form.
      assert {:error, {:live_redirect, %{to: "/sessions"}}} =
               lv
               |> form("#first-session-wizard", %{"wizard" => %{"short_name" => "main"}})
               |> render_submit()

      # session://default/system/main is now registered.
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(URI.new!("session://default/system/main"))
      # …and bound to the default workspace (invariant).
      assert {:ok, _workspace_uri} =
               Ezagent.WorkspaceRegistry.lookup(URI.new!("session://default/system/main"))
    end
  end

  # Terminate every session under EzagentDomainChat.SessionSupervisor so
  # the wizard's empty-list branch can be exercised. Returns the list of
  # session short_names that were torn down (so `on_exit` can re-seed).
  defp drain_sessions do
    sup = Process.whereis(EzagentDomainChat.SessionSupervisor)

    children =
      if sup do
        DynamicSupervisor.which_children(sup)
      else
        []
      end

    shorts =
      for {_id, pid, _type, _modules} <- children, is_pid(pid) do
        Ezagent.KindRegistry.list_all()
        |> Enum.find_value(fn
          {uri_str, ^pid} -> uri_str
          _ -> nil
        end)
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn uri_str -> URI.new!(uri_str).host end)

    for {_id, pid, _type, _modules} <- children, is_pid(pid) do
      DynamicSupervisor.terminate_child(sup, pid)
    end

    wait_until_empty()
    shorts
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
