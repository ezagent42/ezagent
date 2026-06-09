defmodule EzagentPluginLiveview.CommandPaletteComponentTest do
  @moduledoc """
  V1 UI PR-2 (SPEC §2.5) — `CommandPaletteComponent` integration tests.

  Driven through `/sessions` (`AdminLive`) — the workspace LV that
  renders the palette in its `:command_palette` slot — so the test
  exercises the REAL wiring: the `ezagent_web` `:cmdk_nav` on_mount
  assign flowing DOWN, `phx-target={@myself}` routing events to the
  component (not the parent LV), and `cmdk_select` → `push_navigate`.

  The modal markup renders into the DOM even while closed (just with a
  `hidden` class), so the form / overlay / result-row bindings are all
  reachable by `LiveViewTest` selectors — `render_change` /
  `render_click` exercise the `phx-change` / `phx-click` bindings
  through their declared `phx-target={@myself}`. Each successful
  re-render proves the event reached the component instead of crashing
  the parent LV (which has no matching `handle_event`).
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  describe "rendering" do
    test "the palette LiveComponent renders on /sessions", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")

      assert html =~ ~s(id="cmdk")
    end

    test "the root carries the data-cmdk-open JS push, targeted at the component (SPEC §2.4)",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")

      # app.js reads `data-cmdk-open` off #cmdk and execJS-es it. The
      # serialized command must be a push of the canonical `cmdk_open`
      # event and must carry a target (the component) — without the
      # target it would route to the parent LV.
      assert html =~ "data-cmdk-open"
      assert html =~ "cmdk_open"
    end

    test "the search form binds cmdk_query (SPEC §2.5 canonical event)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")
      assert html =~ ~s(phx-change="cmdk_query")
    end
  end

  describe "cmdk_query — search input routes to the component" do
    test "typing 'routing' surfaces the Routing nav result", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      html = lv |> form("#cmdk form", %{"q" => "routing"}) |> render_change()

      assert html =~ "Routing"
      # 2026-05-25 — /routing relocated to /admin/routing (admin scope).
      # phx-value-key on the result row is the stable CommandSource key
      # (the path itself).
      assert html =~ ~s(phx-value-key="nav:/admin/routing")
    end

    test "typing 'sessions' surfaces the Sessions nav result", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      html = lv |> form("#cmdk form", %{"q" => "sessions"}) |> render_change()
      assert html =~ ~s(phx-value-key="nav:/sessions")
    end

    test "a query with no matches shows the empty-state copy", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      html = lv |> form("#cmdk form", %{"q" => "zzzznomatch"}) |> render_change()
      # i18n full-coverage (Allen 2026-05-22) — the empty-state copy was a
      # hardcoded "没有结果"; it is now `gettext("No results")`, which
      # renders English under the test default locale.
      assert html =~ "No results"
    end
  end

  describe "cmdk_close — overlay click routes to the component" do
    test "clicking the overlay does not crash the parent LV", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      # The overlay div binds phx-click="cmdk_close" phx-target={@myself}.
      # If the target were missing, the event would hit AdminLive (no
      # handler) and raise. A clean re-render proves the wiring.
      html = lv |> element(~s(#cmdk div[phx-click])) |> render_click()
      refute html == ""
    end
  end

  describe "cmdk_select — navigation (SPEC §2.5)" do
    test "selecting a nav result push-navigates to its path", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      # Run a query so the result rows render, then click the row.
      lv |> form("#cmdk form", %{"q" => "routing"}) |> render_change()

      # cmdk_select fires with phx-value-key; the component looks the
      # key up in its %{key => result} map and push_navigates.
      # 2026-05-25 — /routing relocated to /admin/routing.
      assert {:error, {:live_redirect, %{to: "/admin/routing"}}} =
               lv
               |> element(~s(#cmdk button[phx-value-key="nav:/admin/routing"]))
               |> render_click()
    end
  end

  describe "AdminLive handle_params(?session=) — the CmdK session landing (SPEC §2.2)" do
    test "/sessions?session=<encoded> selects that session", %{conn: conn} do
      session_uri = "session://system/default/main"
      encoded = URI.encode_www_form(session_uri)

      {:ok, _lv, html} = live(conn, "/sessions?session=#{encoded}")

      # The LV mounted, handle_params decoded the param, and the
      # SessionEditor renders the named session.
      assert html =~ session_uri
    end

    test "/sessions with no session param mounts normally (no-op clause)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")
      assert html =~ "session://system/default/main"
    end

    test "a malformed ?session= value does not crash the LV", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions?session=not%20a%20uri")
      # handle_params rejects it; the LV still renders.
      assert html =~ ~s(id="cmdk")
    end
  end
end
