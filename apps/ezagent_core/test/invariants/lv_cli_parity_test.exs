defmodule EzagentCore.Invariants.LvCliParityTest do
  @moduledoc """
  Retirement invariant for the old LiveView plugin.

  The historical CLI/LV parity scanner walked the old operator LiveViews and
  mapped every mutating `handle_event/3` to an operator CLI. World now owns the
  replacement UI, and the world ratchet is the migration gate. PR-7 flips this
  invariant from "scan the old UI" to "prove the old UI is gone and the world
  ratchet is empty".
  """
  use ExUnit.Case, async: true

  @retired_app Path.expand("../../../ezagent_plugin_liveview", __DIR__)

  @world_ratchet Path.expand(
                   "../../../ezagent_plugin_world/test/ezagent/world/lv_parity_test.exs",
                   __DIR__
                 )

  test "retired LiveView plugin source tree is absent" do
    refute File.dir?(@retired_app),
           "apps/ezagent_plugin_liveview must stay retired; add world coverage instead."
  end

  test "world parity ratchet has reached zero" do
    source = File.read!(@world_ratchet)

    assert Regex.match?(~r/@pending_migration\s+\[\]/, source),
           "world lv_parity_test.exs must keep @pending_migration empty"

    assert Regex.match?(~r/@pending_baseline\s+0\b/, source),
           "world lv_parity_test.exs must keep @pending_baseline at 0"
  end
end
