defmodule EzagentDomainUi.IdeShellTest do
  @moduledoc """
  IDE Shell standalone-atom tests (`editor_tabs/1`, `command_palette/1`).

  Nested-shell PR-3 (SPEC §1, §6 row 3): the old monolithic
  `ide_shell/1` and its body helpers (`activity_bar/1`,
  `activity_items/0`, `activity_for_path/1`, `top_command_bar/1`,
  `status_bar/1`) were deleted once their last consumer migrated.
  Those body helpers were copied into `EzagentDomainUi.WorkspaceShell`
  in PR-1 — their tests now live in `workspace_shell_test.exs`. The
  OUTER chrome (`ide_shell_outer/1`) is covered by
  `ide_shell_outer_test.exs`. Only the standalone presentational
  atoms still defined in `EzagentDomainUi.IdeShell` are tested here.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EzagentDomainUi.IdeShell

  describe "editor_tabs/1" do
    test "renders tab labels + close buttons" do
      assigns = %{
        items: [{:session_main, "main"}, {:terminal_x, "cc_demo"}],
        selected: :session_main
      }

      html =
        rendered_to_string(~H"""
        <IdeShell.editor_tabs items={@items} selected={@selected} />
        """)

      assert html =~ "main"
      assert html =~ "cc_demo"
      # Close button per tab
      assert html =~ ~s(phx-value-key=":session_main")
      assert html =~ ~s(phx-value-key=":terminal_x")
    end
  end

  describe "command_palette/1" do
    test "hidden by default" do
      assigns = %{open: false, query: "", results: []}

      html =
        rendered_to_string(~H"""
        <IdeShell.command_palette open={@open} query={@query} results={@results} />
        """)

      # Container has the "hidden" class when open=false
      assert html =~ "hidden"
    end

    test "renders results when open" do
      assigns = %{
        open: true,
        query: "ses",
        results: [
          %{
            key: "session://system/default/main",
            label: "session://system/default/main",
            icon: "message-square",
            group: "session"
          }
        ]
      }

      html =
        rendered_to_string(~H"""
        <IdeShell.command_palette open={@open} query={@query} results={@results} />
        """)

      assert html =~ "session://system/default/main"
      refute html =~ "没有结果"
    end
  end
end
