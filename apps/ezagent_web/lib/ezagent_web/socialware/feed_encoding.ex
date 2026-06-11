defmodule EzagentWeb.Socialware.FeedEncoding do
  @moduledoc """
  Shared wire-encoding for the socialware `:pull` feed channels (P3-2 customer
  feed + P4 chat feed). Both channels push the SAME `{id, text, sender}` message
  shape to the SAME json-render SPA, so the encoder lives here once rather than
  being copy-pasted per channel (cross-file-duplicate arch gate).
  """

  @doc "Encode a list of `%Message{}`s to the SPA wire shape `[%{id, text, sender}]`."
  @spec encode_messages([Ezagent.Message.t()]) :: [
          %{id: String.t(), text: any(), sender: String.t()}
        ]
  def encode_messages(messages) do
    Enum.map(messages, fn message ->
      %{
        id: message.id,
        text: message_text(message),
        sender: URI.to_string(message.sender)
      }
    end)
  end

  @doc "Extract a message's display text from a string- or atom-keyed body."
  @spec message_text(Ezagent.Message.t()) :: any()
  def message_text(message) do
    Map.get(message.body, "text") || Map.get(message.body, :text)
  end
end
