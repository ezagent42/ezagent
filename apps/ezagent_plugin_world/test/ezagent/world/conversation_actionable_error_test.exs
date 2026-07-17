defmodule Ezagent.World.ConversationActionableErrorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Message.ActionableError
  alias Ezagent.World.ConversationData

  test "message rows project structured actionable errors without parsing fallback prose" do
    sender = Ezagent.URI.new!("entity://team-alpha/agent/curl")
    error = ActionableError.new(:network_timeout, detail: "timeout=15000ms")

    message =
      Ezagent.Message.new(
        sender,
        %{
          text: "upstream API error: timeout",
          attachments: [],
          actionable_error: error
        },
        id: "failure-row"
      )

    row = ConversationData.message_row(message)

    assert row["text"] == "upstream API error: timeout"
    assert row["actionable_error"] == error
    assert row["actionable_error"]["code"] == "agent.network_timeout"
  end
end
