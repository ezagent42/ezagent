defmodule EzagentDomainUi.AdminShellTest do
  @moduledoc """
  Nested-shell refactor PR-1 — `admin_shell/1` render tests.

  `admin_shell` is today's `AdminSettingsShell` BODY (left settings
  nav + main) with its stripped header REMOVED. These tests assert
  the body regions render and the header (Back / centered title /
  close X) is gone.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EzagentDomainUi.AdminShell

  describe "admin_shell/1" do
    test "renders the left settings nav + main, no stripped header" do
      assigns = %{current_path: "/admin"}

      html =
        rendered_to_string(~H"""
        <AdminShell.admin_shell current_path={@current_path}>
          <:main>ADMIN_MAIN_CONTENT</:main>
        </AdminShell.admin_shell>
        """)

      assert html =~ ~s(id="admin-shell")
      assert html =~ ~s(id="admin-shell-sidebar")
      assert html =~ ~s(id="admin-shell-main")
      assert html =~ "ADMIN_MAIN_CONTENT"
      # Left settings nav lists the sub-sections.
      assert html =~ "Overview"
      assert html =~ "Workspaces"
      assert html =~ "Registry"
      # The stripped header (Back / centered title / close X) is
      # REMOVED — the universal header is now owned by the outer shell.
      refute html =~ "Back to ezagent"
      refute html =~ ~s(id="admin-settings-topbar")
      refute html =~ ~s(aria-label="Close admin settings")
    end

    test "active_section explicit value highlights that sidebar item" do
      assigns = %{current_path: "/admin", active_section: :registry}

      html =
        rendered_to_string(~H"""
        <AdminShell.admin_shell
          current_path={@current_path}
          active_section={@active_section}
        >
          <:main>x</:main>
        </AdminShell.admin_shell>
        """)

      assert html =~ ~s(aria-current="page")
    end

    test "active_section defaults to section_for_path(current_path)" do
      assigns = %{current_path: "/admin/snapshots"}

      html =
        rendered_to_string(~H"""
        <AdminShell.admin_shell current_path={@current_path}>
          <:main>x</:main>
        </AdminShell.admin_shell>
        """)

      assert html =~ ~s(aria-current="page")
    end

    test "does NOT render an Activity Bar or status bar" do
      assigns = %{current_path: "/admin"}

      html =
        rendered_to_string(~H"""
        <AdminShell.admin_shell current_path={@current_path}>
          <:main>x</:main>
        </AdminShell.admin_shell>
        """)

      refute html =~ ~s(id="workspace-shell")
      refute html =~ ~s(aria-label="Sessions")
    end
  end

  describe "section helpers" do
    test "sections/0 returns the 7 sub-sections in display order" do
      # G-1 + G-2 V0 stop-gap (audit 2026-05-23) — `:templates` added
      # between `:snapshots` and `:settings`. AgentTemplate +
      # SessionTemplate Kinds list lives at /admin/templates.
      keys = Enum.map(AdminShell.sections(), & &1.key)
      assert keys == [:overview, :workspaces, :logs, :registry, :snapshots, :templates, :settings]
    end

    test "section_for_path/1 maps known paths" do
      assert AdminShell.section_for_path("/admin") == :overview
      assert AdminShell.section_for_path("/admin/logs") == :logs
      assert AdminShell.section_for_path("/admin/registry") == :registry
      assert AdminShell.section_for_path("/admin/snapshots") == :snapshots
      assert AdminShell.section_for_path("/admin/templates") == :templates
      assert AdminShell.section_for_path("/admin/settings") == :settings
      assert AdminShell.section_for_path("/workspaces") == :workspaces
      assert AdminShell.section_for_path("/workspaces/demo") == :workspaces
      assert AdminShell.section_for_path("/sessions") == :overview
      assert AdminShell.section_for_path(nil) == :overview
    end
  end
end
