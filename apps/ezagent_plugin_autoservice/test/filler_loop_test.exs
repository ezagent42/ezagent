defmodule EzagentPluginAutoservice.FillerLoopTest do
  use ExUnit.Case, async: true

  alias EzagentPluginAutoservice.FillerLoop

  @test_session_uri "urn:ezagent:session:test-filler"
  @test_agent_uri "urn:ezagent:agent:test-fast"

  describe "start/3" do
    test "spawns a task and completes without error" do
      task = FillerLoop.start(@test_session_uri, @test_agent_uri,
        interval_ms: 10,
        max_count: 2,
        timeout_ms: 5000
      )

      assert %Task{} = task
      assert :ok = Task.await(task, 5000)
    end
  end

  describe "timeout_apology/0" do
    test "returns a non-empty string" do
      msg = FillerLoop.timeout_apology()
      assert is_binary(msg)
      assert String.length(msg) > 0
    end
  end
end
