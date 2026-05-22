defmodule EzagentDomainUi.WorkspaceShellTest do
  @moduledoc """
  Nested-shell refactor PR-1 — `workspace_shell/1` render tests.

  `workspace_shell` is today's `ide_shell` BODY (Activity Bar +
  Resource Panel + Main Window + Right Sidebar + Status Bar) with the
  universal header REMOVED. These tests assert the body regions render
  and the header is gone.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EzagentDomainUi.WorkspaceShell

  describe "workspace_shell/1" do
    test "renders Activity Bar + Main Window + Status Bar, no universal header" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        current_path: "/sessions",
        status: %{agents_alive: 0, bridges: 0, debug_events: 0, version: "test"}
      }

      html =
        rendered_to_string(~H"""
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri}
          current_path={@current_path}
          status={@status}
        >
          <:main_window>MAIN_CONTENT</:main_window>
        </WorkspaceShell.workspace_shell>
        """)

      assert html =~ ~s(id="workspace-shell")
      # Activity Bar — 4 items.
      assert html =~ "Sessions"
      assert html =~ "Identities"
      assert html =~ "Routing"
      assert html =~ "Plugins"
      # Main Window slot rendered.
      assert html =~ "MAIN_CONTENT"
      # Status Bar.
      assert html =~ "agents"
      assert html =~ "bridges"
      assert html =~ "events"
      # The universal header is REMOVED — no search/⌘K trigger, no
      # workspace dropdown, no avatar menu in the body component.
      refute html =~ "⌘K"
      refute html =~ ~s(aria-label="Switch workspace")
      refute html =~ ~s(aria-label="Your profile")
    end

    test "renders the resource_panel slot when given" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        current_path: "/sessions",
        status: %{}
      }

      html =
        rendered_to_string(~H"""
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri}
          current_path={@current_path}
          status={@status}
        >
          <:resource_panel>RESOURCE_PANEL</:resource_panel>
          <:main_window>main</:main_window>
        </WorkspaceShell.workspace_shell>
        """)

      assert html =~ "RESOURCE_PANEL"
      assert html =~ ~s(id="left-resource-panel")
    end

    test "renders the right_sidebar slot + Members toggle when given" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        current_path: "/sessions",
        status: %{}
      }

      html =
        rendered_to_string(~H"""
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri}
          current_path={@current_path}
          status={@status}
        >
          <:main_window>main</:main_window>
          <:right_sidebar>RIGHT_SIDEBAR</:right_sidebar>
        </WorkspaceShell.workspace_shell>
        """)

      assert html =~ "RIGHT_SIDEBAR"
      assert html =~ ~s(id="right-sidebar")
      # Members toggle lives in the status bar (header/statusbar
      # separation principle).
      assert html =~ ~s(aria-label="Toggle members panel")
    end

    test "no resource panel / right sidebar → no orphan toggles" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        current_path: "/sessions",
        status: %{}
      }

      html =
        rendered_to_string(~H"""
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri}
          current_path={@current_path}
          status={@status}
        >
          <:main_window>main</:main_window>
        </WorkspaceShell.workspace_shell>
        """)

      refute html =~ ~s(id="left-resource-panel")
      refute html =~ ~s(id="right-sidebar")
      refute html =~ ~s(aria-label="Toggle members panel")
    end
  end

  describe "activity helpers" do
    test "activity_items/0 returns the 4 SPEC-defined items" do
      keys = Enum.map(WorkspaceShell.activity_items(), & &1.key)
      assert keys == [:sessions, :identities, :routing, :plugins]
    end

    test "activity_for_path/1 maps known paths" do
      assert WorkspaceShell.activity_for_path("/sessions") == :sessions
      assert WorkspaceShell.activity_for_path("/identities") == :identities
      assert WorkspaceShell.activity_for_path("/routing") == :routing
      assert WorkspaceShell.activity_for_path("/plugins") == :plugins
      assert WorkspaceShell.activity_for_path("/admin/logs") == nil
      assert WorkspaceShell.activity_for_path("/workspaces") == nil
      assert WorkspaceShell.activity_for_path("/unknown") == :sessions
    end
  end
end
