defmodule Ezagent.Socialware.ViewerNavAssetTest do
  use ExUnit.Case, async: true

  @nav_test Path.expand("../../assets/test/viewer_nav_test.mjs", __DIR__)

  test "viewer executes unseen whitelisted navigation independent of agent URI names" do
    {output, status} = System.cmd("node", [@nav_test], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "viewer navigation contract: ok"
  end
end
