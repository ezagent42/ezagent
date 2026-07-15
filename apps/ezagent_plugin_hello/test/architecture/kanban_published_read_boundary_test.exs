defmodule EzagentPluginHello.KanbanPublishedReadBoundaryTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../lib/ezagent_plugin_hello", __DIR__)
  @forbidden [
    "Kind.get_slice(",
    "Capability.issue(",
    "Cap.issue(",
    "list_caps_for(",
    "{:set, :tree",
    "\"tree\" =>",
    "MountRow."
  ]

  test "published-read boundary stores references and delegates instead of copying Kanban authority" do
    files =
      [Path.join(@root, "kanban_published_read.ex")] ++
        Path.wildcard(Path.join(@root, "kanban_published_read/**/*.ex")) ++
        [Path.join(@root, "published_board_ref.ex")]

    assert Enum.all?(files, &File.regular?/1)

    source = Enum.map_join(files, "\n", &File.read!/1)

    for forbidden <- @forbidden do
      refute String.contains?(source, forbidden),
             "published-read boundary must not contain #{inspect(forbidden)}"
    end

    assert String.contains?(source, "PublishedBoardRef")
    assert String.contains?(source, ":dependency_not_landed")
  end
end
