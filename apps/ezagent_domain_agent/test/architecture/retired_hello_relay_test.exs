defmodule EzagentDomainAgent.Architecture.RetiredHelloRelayTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  test "the agent receive seam has no route or cap reference to the deleted Hello action" do
    receive_source =
      File.read!(
        Path.join(@repo_root, "apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex")
      )

    cap_source = File.read!(Path.join(@repo_root, "apps/ezagent_core/lib/ezagent/cap.ex"))

    refute receive_source =~ ~S|sync_result_action("hello")|
    refute receive_source =~ ":hello_sync_result"
    refute cap_source =~ ":hello_sync_result"
  end
end
