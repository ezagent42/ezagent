defmodule EzagentDomainUi.IdeShellOuterTest do
  @moduledoc """
  Nested-shell refactor PR-1 — `ide_shell_outer/1` render tests.

  `ide_shell_outer` is the Tier-2 OUTER chrome: universal header +
  `:command_palette` slot + `:body` slot. The `perspective` attr
  (SPEC §2) governs the header's left context affordance:

  - `:workspace` → workspace dropdown (or plain `ezagent / <ws>` text)
  - `:admin`     → plain `ezagent · System` system-context label

  These tests also confirm the existing `ide_shell/1` monolith is
  left intact (additive-only invariant, SPEC §6 row 1).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EzagentDomainUi.IdeShell

  describe "ide_shell_outer/1 — :workspace perspective" do
    test "renders header + body + command_palette; workspace dropdown when workspaces given" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        workspace_name: "default",
        workspaces: [
          %{name: "default", uri: "workspace://default"},
          %{name: "demo", uri: "workspace://demo"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <IdeShell.ide_shell_outer
          perspective={:workspace}
          current_entity_uri={@current_entity_uri}
          workspace_name={@workspace_name}
          workspaces={@workspaces}
        >
          <:command_palette>CMDK_SLOT</:command_palette>
          <:body>BODY_SLOT</:body>
        </IdeShell.ide_shell_outer>
        """)

      assert html =~ ~s(id="ide-shell-outer")
      # Universal header chrome.
      assert html =~ "⌘K"
      assert html =~ ~s(aria-label="Your profile")
      # Body + command palette slots rendered.
      assert html =~ "BODY_SLOT"
      assert html =~ "CMDK_SLOT"
      # :workspace perspective with a workspaces list → workspace dropdown.
      assert html =~ ~s(id="workspace-menu")
      assert html =~ ~s(aria-label="Switch workspace")
      # NOT the admin system label.
      refute html =~ "ezagent</span>\n          <span class=\"text-zinc-400 dark:text-zinc-600 select-none\">·"
    end

    test "plain `ezagent / <ws>` text when workspaces list is empty" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        workspace_name: "default"
      }

      html =
        rendered_to_string(~H"""
        <IdeShell.ide_shell_outer
          perspective={:workspace}
          current_entity_uri={@current_entity_uri}
          workspace_name={@workspace_name}
        >
          <:body>body</:body>
        </IdeShell.ide_shell_outer>
        """)

      assert html =~ "ezagent"
      assert html =~ "default"
      refute html =~ ~s(aria-label="Switch workspace")
    end
  end

  describe "ide_shell_outer/1 — :admin perspective" do
    test "shows the plain `ezagent · System` label, NOT the workspace dropdown" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        # An :admin page must NOT show the tenant switcher even if a
        # workspaces list is somehow passed.
        workspaces: [%{name: "default", uri: "workspace://default"}]
      }

      html =
        rendered_to_string(~H"""
        <IdeShell.ide_shell_outer
          perspective={:admin}
          current_entity_uri={@current_entity_uri}
          workspaces={@workspaces}
        >
          <:body>ADMIN_BODY</:body>
        </IdeShell.ide_shell_outer>
        """)

      # System-context label present.
      assert html =~ "System"
      # Workspace dropdown ABSENT — you do not switch tenant workspace
      # while editing global config (SPEC §2).
      refute html =~ ~s(id="workspace-menu")
      refute html =~ ~s(aria-label="Switch workspace")
      # Universal chrome still present + body rendered.
      assert html =~ "⌘K"
      assert html =~ "ADMIN_BODY"
    end
  end

  describe "additive-only invariant (SPEC §6 row 1)" do
    test "the old ide_shell/1 monolith still renders unchanged" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        current_path: "/sessions",
        status: %{}
      }

      html =
        rendered_to_string(~H"""
        <IdeShell.ide_shell
          current_entity_uri={@current_entity_uri}
          current_path={@current_path}
          status={@status}
        >
          <:main_window>OLD_MONOLITH</:main_window>
        </IdeShell.ide_shell>
        """)

      # The old monolith keeps its own root id + chrome — proof PR-1
      # added next to it rather than replacing it.
      assert html =~ ~s(id="ide-shell")
      assert html =~ "OLD_MONOLITH"
      assert html =~ "⌘K"
    end

    test "old + new shells coexist as distinct functions" do
      # Both exported; neither renamed. ensure_loaded! so the check
      # doesn't depend on lazy module loading.
      {:module, IdeShell} = Code.ensure_loaded(IdeShell)
      assert function_exported?(IdeShell, :ide_shell, 1)
      assert function_exported?(IdeShell, :ide_shell_outer, 1)
    end
  end
end
