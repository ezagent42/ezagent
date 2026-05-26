defmodule EzagentDomainUi.IdeShellOuterTest do
  @moduledoc """
  Nested-shell refactor PR-1 — `ide_shell_outer/1` render tests.

  `ide_shell_outer` is the Tier-2 OUTER chrome: universal header +
  `:command_palette` slot + `:body` slot. The `perspective` attr
  (SPEC §2) governs the header's left context affordance:

  - `:workspace` → workspace dropdown (always, including empty list
    — the dropdown is the sole entry to `/workspaces`)
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
          %{name: "default", uri: "workspace://team-alpha"},
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

    test "dropdown still rendered when workspaces list is empty — with placeholder + Manage workspaces link" do
      # Regression test for workspace-rename (#335) follow-up: when
      # the DB has no visible workspaces (only the hidden `system`
      # seed), the dropdown trigger MUST stay visible. Otherwise
      # first-time operators have NO way to reach `/workspaces` to
      # create the first one — Activity Bar dropped its Workspaces
      # tile in PR-L. Allen reported this regression in Feishu on
      # 2026-05-25.
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        workspace_name: nil
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

      # Dropdown trigger is ALWAYS present in :workspace perspective.
      assert html =~ ~s(id="workspace-menu")
      assert html =~ ~s(aria-label="Switch workspace")
      # Empty-state placeholder body so the menu doesn't look broken.
      assert html =~ "No workspaces yet"
      # The footer link is reachable — this is the invariant that
      # broke before this fix (regression test).
      assert html =~ ~s(href="/workspaces")
      assert html =~ "Manage workspaces"
    end
  end

  describe "ide_shell_outer/1 — :admin perspective" do
    test "shows the plain `ezagent · System` label, NOT the workspace dropdown" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        # An :admin page must NOT show the tenant switcher even if a
        # workspaces list is somehow passed.
        workspaces: [%{name: "default", uri: "workspace://team-alpha"}]
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

  describe "workspace dropdown z-index — paints above the left resource panel" do
    # Regression test for Allen 2026-05-26 — the workspace switcher
    # dropdown ("ezagent / <ws>" button → menu) opened BEHIND the left
    # resource panel on pages like /identities, /plugins, /sessions
    # because both used `z-40`. Same z-index + later-in-DOM sibling →
    # later wins, so the resource panel painted on top of the dropdown.
    #
    # The avatar menu (right side) already had z-50 from the 2026-05-22
    # avatar dropdown fix (see `avatar_menu/1` comment). This test pins
    # the symmetric fix on the workspace dropdown so a future edit
    # downgrading the class is caught by CI.
    test "workspace-menu element carries z-50 (above z-40 chrome)" do
      assigns = %{
        current_entity_uri: "entity://user/system/admin",
        workspace_name: "default",
        workspaces: [%{name: "default", uri: "workspace://default"}]
      }

      html =
        rendered_to_string(~H"""
        <IdeShell.ide_shell_outer
          perspective={:workspace}
          current_entity_uri={@current_entity_uri}
          workspace_name={@workspace_name}
          workspaces={@workspaces}
        >
          <:body>body</:body>
        </IdeShell.ide_shell_outer>
        """)

      # Extract the workspace-menu element's class attribute.
      assert [_, menu_class] =
               Regex.run(
                 ~r/id="workspace-menu"[^>]*class="([^"]+)"/,
                 html
               )

      # The dropdown body sits above the z-40 left resource panel /
      # right sidebar / activity bar items. Without z-50, the menu
      # paints behind them on lg+ screens.
      assert menu_class =~ "z-50",
             "expected workspace-menu to carry z-50 (above z-40 chrome); got class=#{menu_class}"

      refute menu_class =~ "z-40",
             "workspace-menu must not have z-40 — same-z + later-in-DOM sibling (resource panel) wins"
    end
  end

  describe "avatar menu — System theme button" do
    # Regression test for Allen 2026-05-26 — the avatar-menu theme
    # picker had three buttons labeled "Light theme" / "Dark theme" /
    # "System". The bare "System" label was ambiguous (in zh_CN it
    # rendered as just "系统" — Allen read it as a navigation entry to
    # an "admin / system area" rather than a theme picker). Fix:
    # rename to "System theme" so the three labels are parallel.
    #
    # The phx-click handler was always wired (JS.dispatch("phx:set-
    # theme") + data-phx-theme="system" → root.html.heex window
    # listener writes localStorage and sets data-theme to the OS
    # preferred value). The bug was purely the label.
    test "avatar menu has 3 parallel theme buttons (Light / Dark / System) — all click-wired" do
      assigns = %{current_entity_uri: "entity://user/system/admin", is_admin?: true}

      html =
        rendered_to_string(~H"""
        <IdeShell.avatar_menu
          current_entity_uri={@current_entity_uri}
          is_admin?={@is_admin?}
        />
        """)

      # All three theme buttons present + click-wired via phx:set-theme
      # dispatch + their data-phx-theme payload.
      assert html =~ ~s(data-phx-theme="light")
      assert html =~ ~s(data-phx-theme="dark")
      assert html =~ ~s(data-phx-theme="system")

      # Parallel labels — "System theme" not bare "System". Catches
      # accidental revert to the ambiguous label.
      assert html =~ "Light theme"
      assert html =~ "Dark theme"
      assert html =~ "System theme"

      # Each button carries phx-click dispatching phx:set-theme.
      # Count occurrences — must be exactly 3 (Light + Dark + System).
      assert length(Regex.scan(~r/phx:set-theme/, html)) == 3
      # dispatch action present (HTML-entity-encoded in attribute).
      assert html =~ "dispatch"
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
