defmodule Ezagent.Entity.AgentTest do
  use ExUnit.Case, async: true

  test "echo_behaviors is base + Echo, and behaviors/0 superset includes Echo" do
    echo = Ezagent.Entity.Agent.echo_behaviors()
    assert Ezagent.Behavior.Identity in echo
    assert Ezagent.Behavior.Echo in echo
    assert Ezagent.Behavior.Echo in Ezagent.Entity.Agent.behaviors()
    # nil-capture default must NOT include Echo (cc/codex unaffected)
    refute Ezagent.Behavior.Echo in Ezagent.Entity.Agent.nil_capture_behavior_set()
  end
end
