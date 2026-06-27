defmodule Ezagent.ProtocolApi.ResponseRenderer do
  @moduledoc """
  Renders an internal agent reply into a protocol-shaped response body
  for the LLM Protocol API (#96 Phase 1).

  One function per protocol response shape. Today only the OpenAI
  `chat.completion` object is rendered; Phase 2 adds the OpenAI Responses and
  Anthropic Messages shapes alongside it.
  """

  alias Ezagent.Message

  @doc """
  Render an agent reply as an OpenAI `chat.completion` object.

  Byte-identical to the previous inline `build_openai_response/2`: the assistant
  content is the reply message body's `:text` (atom or string key), defaulting to
  an empty string; token usage is reported as zero.
  """
  @spec openai_chat_completion(String.t(), Message.t()) :: map()
  def openai_chat_completion(request_id, %Message{} = reply_msg) do
    %{
      "id" => "chatcmpl-#{request_id}",
      "object" => "chat.completion",
      "created" => DateTime.utc_now() |> DateTime.to_unix(),
      "model" => "ezagent",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => Map.get(reply_msg.body, :text) || Map.get(reply_msg.body, "text") || ""
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
    }
  end
end
