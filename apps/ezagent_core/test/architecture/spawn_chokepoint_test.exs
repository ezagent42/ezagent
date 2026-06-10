Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.SpawnChokepointTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "SpawnRegistry spawn writers do not grow beyond baseline" do
    assert_at_or_below(:spawn_registry_call_sites)
    assert_at_or_below(:spawn_registry_modules)
    assert_at_or_below(:spawn_registry_off_chokepoint_modules)
  end

  test "create_session/3 caller surface does not grow beyond baseline" do
    assert_at_or_below(:create_session_call_sites)
    assert_at_or_below(:create_session_modules)
  end

  test "spawn_fresh audit surface is frozen and unsanctioned calls stay zero" do
    assert_at_or_below(:spawn_fresh_audit_references)
    assert_zero(:spawn_fresh_unsanctioned)
  end
end
