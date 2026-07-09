defmodule Ezagent.Routing.TraceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Routing.Trace

  test "records and returns a message journey in insertion order" do
    message_id = "trace-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Trace.record(%{
               message_id: message_id,
               workspace_uri: "workspace://system",
               rule_id: 12,
               receivers: ["entity://system/agent/builder"],
               hop: 7,
               drop_reason: nil
             })

    assert {:ok, _} =
             Trace.record(%{
               message_id: message_id,
               workspace_uri: "workspace://system",
               rule_id: :no_match,
               receivers: [],
               hop: 7,
               drop_reason: :no_match
             })

    assert [
             %{rule_id: "12", receivers: ["entity://system/agent/builder"], hop: 7},
             %{rule_id: "no_match", receivers: [], drop_reason: "no_match"}
           ] = Trace.journey(message_id)
  end
end
