defmodule Ezagent.ProtocolApi.ResponseRendererTest do
  @moduledoc """
  P1 test-supplement — pure-function shaping tests for the OpenAI
  `chat.completion` response renderer. Not security-sensitive by itself,
  but it's the response half of the authenticated dispatch contract
  (priority 2: "authenticated route -> action dispatch mapping").
  """

  use ExUnit.Case, async: true

  alias Ezagent.Message
  alias Ezagent.ProtocolApi.ResponseRenderer

  test "renders an atom-keyed :text body into the OpenAI chat.completion shape" do
    msg = Message.new(entity_uri(), %{text: "hello there", attachments: []})

    resp = ResponseRenderer.openai_chat_completion("req-123", msg)

    assert resp["id"] == "chatcmpl-req-123"
    assert resp["object"] == "chat.completion"
    assert is_integer(resp["created"])
    assert resp["model"] == "ezagent"
    assert [%{"index" => 0, "message" => message, "finish_reason" => "stop"}] = resp["choices"]
    assert message["role"] == "assistant"
    assert message["content"] == "hello there"
    assert resp["usage"] == %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
  end

  test "falls back to a string-keyed \"text\" body when the atom key is absent" do
    msg = %Message{body: %{"text" => "string keyed"}, id: "m1", sender: entity_uri()}

    resp = ResponseRenderer.openai_chat_completion("req-456", msg)

    assert get_in(resp, ["choices", Access.at(0), "message", "content"]) == "string keyed"
  end

  test "missing text in the body defaults to an empty string (never crashes on a bare reply)" do
    msg = %Message{body: %{}, id: "m2", sender: entity_uri()}

    resp = ResponseRenderer.openai_chat_completion("req-789", msg)

    assert get_in(resp, ["choices", Access.at(0), "message", "content"]) == ""
  end

  defp entity_uri, do: Ezagent.URI.new!("entity://system/agent/py_default")
end
