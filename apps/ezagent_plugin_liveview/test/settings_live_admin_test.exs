defmodule EzagentPluginLiveview.SettingsLiveAdminTest do
  @moduledoc """
  V1 fix (Allen Feishu 2026-05-21 17:44) — `/settings` was moved to
  `/admin/settings` because its contents (SMTP + registration domains)
  are admin-only.

  These tests pin the new placement contract:

    1. /admin/settings is admin-only at the mount level (non-admin
       callers are redirected, not just shown a no-op page).
    2. The page renders inside the admin perspective — nested-shell
       PR-3 wraps it in `AppShell.app_shell` (`perspective: :admin`)
       over `AdminShell.admin_shell` — same shell stack as /admin,
       /admin/logs, /admin/registry, /admin/snapshots, /workspaces.
       It carries the universal outer chrome (`ide-shell-outer`) +
       the admin inner perspective (`admin-shell`), and does NOT use
       the workspace inner perspective.
    3. The SMTP form is still wired correctly at the new URL
       (regression coverage on top of `settings_live_smtp_test.exs`).
  """
  use ExUnit.Case

  # #52 Mode-A: cross-tier LiveView suite — mounts views that resolve
  # sibling-app domain modules; runs only in the umbrella. Excluded
  # standalone (`cd apps/ezagent_plugin_liveview && mix test`).
  @moduletag :umbrella_only
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  defp admin_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
    })
  end

  defp non_admin_conn do
    # Provision a regular (non-admin) user so the session reflects a
    # real entity that EzagentWeb.Plugs.RequireEntity will accept but
    # `Ezagent.Identity.admin?/1` will reject. The URI must be a
    # 3-segment entity URI (workspace segment required, SPEC v3 §5.15).
    uri = "entity://team-alpha/user/v1_settings_to_admin_test_user"
    {:ok, _user} = Ezagent.Users.create(URI.parse(uri), nil, [])

    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{"current_entity_uri" => uri})
  end

  describe "/admin/settings admin gate" do
    test "admin caller mounts successfully" do
      {:ok, _lv, html} = live(admin_conn(), "/admin/settings")
      # Page rendered (not a redirect).
      assert html =~ "Email / SMTP" or html =~ "Settings"
    end

    test "non-admin caller is redirected away from /admin/settings" do
      # The V1 mount-gate redirects to /sessions with a flash; the
      # `live/2` helper surfaces that as `{:error, {:live_redirect, _}}`
      # (or `{:redirect, _}` depending on whether push_navigate fires
      # before or after the initial render). Accept either shape.
      assert {:error, redirect} = live(non_admin_conn(), "/admin/settings")
      assert match?({:live_redirect, %{to: "/sessions"}}, redirect) or
               match?({:redirect, %{to: "/sessions"}}, redirect)
    end
  end

  describe "/admin/settings renders in the admin perspective" do
    test "page is in the admin perspective (not the workspace perspective)" do
      {:ok, _lv, html} = live(admin_conn(), "/admin/settings")

      # Nested-shell PR-3 — the universal outer chrome wraps the page.
      assert html =~ ~s(id="ide-shell-outer")
      # The admin inner perspective body + its left settings nav.
      assert html =~ ~s(id="admin-shell")
      assert html =~ ~s(id="admin-shell-sidebar")

      # The workspace inner perspective MUST NOT appear — /admin/settings
      # is a system-config surface, not a workspace surface.
      refute html =~ ~s(id="workspace-shell")
    end

    test "drawer sidebar includes a Settings entry pointing at /admin/settings" do
      {:ok, _lv, html} = live(admin_conn(), "/admin/settings")
      assert html =~ ~s(href="/admin/settings")
    end

    test "page gains the universal chrome it previously lacked (avatar / search / ⌘K)" do
      # Nested-shell SPEC §8 — the 7 admin pages now carry the universal
      # chrome. The old chrome-less AdminSettingsShell had none of it.
      {:ok, _lv, html} = live(admin_conn(), "/admin/settings")

      # Search / ⌘K trigger.
      assert html =~ "⌘K"
      # CommandPaletteComponent is wired (its root carries id="cmdk").
      assert html =~ ~s(id="cmdk")
    end
  end

  describe "/admin/settings SMTP form" do
    test "save_smtp still works at the new URL (regression)" do
      {:ok, lv, _html} = live(admin_conn(), "/admin/settings")

      smtp_complete = %{
        "host" => "smtp.example.com",
        "port" => "587",
        "username" => "postmaster@example.com",
        "password" => "secret-pw-1",
        "from_address" => "no-reply@example.com",
        "tls" => "true"
      }

      html = lv |> render_submit("save_smtp", %{"smtp" => smtp_complete})
      assert html =~ "SMTP config saved."
      assert Ezagent.AppSettings.smtp_configured?()
    end
  end

  describe "old /settings route is GONE" do
    test "GET /settings falls through to the 404 fallback (not SettingsLive)" do
      # The LV route at /settings was removed in this V1 fix. The
      # router has a catch-all `get "/*path", FallbackController,
      # :not_found` that handles anything unmatched — so /settings
      # now returns 404 rather than mounting SettingsLive.
      conn = get(admin_conn(), "/settings")
      assert conn.status == 404

      # And — crucially — the SettingsLive shell ids must NOT appear
      # (proves the LV did NOT mount at the old URL).
      body = response(conn, 404)
      refute body =~ ~s(id="admin-shell")
    end
  end
end
