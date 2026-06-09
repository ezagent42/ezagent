Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.RespawnRoundTripTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "cold-restart respawn round-trip drift stays zero" do
    assert_zero(:cold_restart_respawn_round_trip_drift)
  end
end
