defmodule EzagentWeb.Socialware.FeedEncoding do
  @moduledoc """
  Shared wire-encoding for the socialware `:pull` feed channels (P3-2 customer
  feed + P4 chat feed). Both channels push the SAME `{id, text, sender}` message
  shape to the SAME json-render SPA, so the encoder lives here once rather than
  being copy-pasted per channel (cross-file-duplicate arch gate).
  """

  @doc """
  Encode a list of `%Message{}`s to the SPA wire shape
  `[%{id, text, sender, render}]`. `render` is an optional json-render node tree
  (`body["render"]`) — when present the bubble renders it with the SAME engine as
  the preview page, instead of plain text. Same spec format as the Surface page,
  so a fragment generated for the page can be reused verbatim in a message.
  """
  @spec encode_messages([Ezagent.Message.t()]) :: [
          %{id: String.t(), text: any(), sender: String.t(), render: term()}
        ]
  def encode_messages(messages) do
    Enum.map(messages, fn message ->
      %{
        id: message.id,
        text: message_text(message),
        sender: URI.to_string(message.sender),
        render: message_render(message),
        render_css: message_render_css(message)
      }
    end)
  end

  @doc "Extract a message's display text from a string- or atom-keyed body."
  @spec message_text(Ezagent.Message.t()) :: any()
  def message_text(message) do
    Map.get(message.body, "text") || Map.get(message.body, :text)
  end

  @doc "The optional json-render node tree carried in a message body, or nil."
  @spec message_render(Ezagent.Message.t()) :: term()
  def message_render(message) do
    Map.get(message.body, "render") || Map.get(message.body, :render)
  end

  @doc "The optional per-card CSS theme carried in a message body, or nil."
  @spec message_render_css(Ezagent.Message.t()) :: term()
  def message_render_css(message) do
    Map.get(message.body, "render_css") || Map.get(message.body, :render_css)
  end
end
