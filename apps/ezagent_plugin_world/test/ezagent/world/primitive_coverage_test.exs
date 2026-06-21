defmodule Ezagent.World.PrimitiveCoverageTest do
  use ExUnit.Case, async: true

  @expected ~w(
    button input card badge page_header breadcrumb stat plugin_card flash_group
    status_dot avatar tabs modal toast tree_list empty_state form_field uri_chip
    toolbar tooltip icon uri_picker workspace_shell activity_bar status_bar
    admin_shell sidebar_nav ide_shell_outer editor_tabs split_pane command_palette
    pty_terminal routing_view external_mirror_view
  )

  test "React primitive barrel covers the ezagent_domain_ui atom layer" do
    source =
      File.read!(
        Path.expand(
          "../../../assets/src/components/ui/primitives.tsx",
          __DIR__
        )
      )

    exported =
      ~r/"([a-z_]+)"/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    missing =
      @expected
      |> MapSet.new()
      |> MapSet.difference(exported)
      |> MapSet.to_list()

    assert missing == []
  end
end
