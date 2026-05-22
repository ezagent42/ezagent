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

  describe "old monolith deleted (SPEC §6 row 3 — nested-shell PR-3)" do
    test "the old monolithic ide_shell/1 is gone — only ide_shell_outer/1 remains" do
      # PR-1 added `ide_shell_outer/1` next to the old `ide_shell/1`
      # (additive). PR-3 migrated the last consumer off `ide_shell/1`
      # and deleted it in the SAME PR (SPEC §6 row 3). The OUTER shell
      # is now the sole shell entry point in this module.
      {:module, IdeShell} = Code.ensure_loaded(IdeShell)
      refute function_exported?(IdeShell, :ide_shell, 1)
      assert function_exported?(IdeShell, :ide_shell_outer, 1)
    end

    test "the old monolith's body helpers are gone (copied into WorkspaceShell in PR-1)" do
      # `activity_bar/1`, `activity_items/0`, `activity_for_path/1`,
      # `top_command_bar/1`, `status_bar/1` were body helpers of the
      # deleted `ide_shell/1`. They were copied into
      # `EzagentDomainUi.WorkspaceShell` in PR-1; PR-3 deletes the
      # now-dead originals here.
      {:module, IdeShell} = Code.ensure_loaded(IdeShell)
      refute function_exported?(IdeShell, :activity_bar, 1)
      refute function_exported?(IdeShell, :activity_items, 0)
      refute function_exported?(IdeShell, :activity_for_path, 1)
      refute function_exported?(IdeShell, :top_command_bar, 1)
      refute function_exported?(IdeShell, :status_bar, 1)
    end
  end
end
