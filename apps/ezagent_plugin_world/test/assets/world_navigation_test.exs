defmodule EzagentPluginWorld.Assets.WorldNavigationTest do
  @moduledoc """
  Runs the world React-island navigation contract under Node.

  The world console lives inside a LiveView hook. Internal world links must be
  intercepted and sent to `WorldLive` as patch navigation; external links,
  downloads, and modified clicks must remain native browser navigation.
  """
  use ExUnit.Case, async: true

  @navigation_test Path.expand("../../assets/test/world_navigation_test.mjs", __DIR__)

  test "world navigation click interception contract" do
    {output, status} = System.cmd("node", [@navigation_test], stderr_to_stdout: true)
    assert status == 0, output
  end
end
