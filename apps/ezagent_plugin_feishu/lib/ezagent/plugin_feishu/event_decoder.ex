defmodule EzagentPluginFeishu.EventDecoder do
  @moduledoc """
  Phase 6 PR 15 — translate a raw Feishu `message` event object into
  Ezagent's `body` shape (`%{text:, attachments:}`).

  Same algorithm used by `WebhookPlug` (HTTP transport) and `WsClient`
  (WSS long-connect transport). Pulled out so both share the dispatch
  format without one calling the other's test helper.

  ## Mapping

  Feishu `message_type` → body shape:

  | Feishu type | text                              | attachments               |
  |-------------|-----------------------------------|---------------------------|
  | text        | content.text                      | []                        |
  | image       | ""                                | [%{type: :image, file_key}]|
  | file        | ""                                | [%{type: :file, file_key, name, size_bytes}] |
  | audio       | ""                                | [%{type: :audio, file_key, duration}] |
  | media       | ""                                | [%{type: :video, file_key, duration}] |
  | other       | "[feishu message_type=X unhandled..]" | []                  |

  Per Allen 2026-05-17 "理论上应该将所有信息都传入channel，即使没办
  法处理，至少让cc/user知道尝试传了什么type的信息" — unknown types
  become a text breadcrumb so downstream sees the attempt.
  """

  @doc """
  Convert a Feishu `"message"` payload to an Ezagent body map.

      iex> EzagentPluginFeishu.EventDecoder.build_body(
      ...>   %{"message_type" => "text", "content" => ~s({"text":"hi"}), "message_id" => "om_x"}
      ...> )
      %{text: "hi", attachments: []}
  """
  @spec build_body(map()) :: %{text: String.t(), attachments: [map()]}
  def build_body(msg) when is_map(msg) do
    msg_type = Map.get(msg, "message_type", "unknown")
    message_id = Map.get(msg, "message_id")
    content = decode_content(Map.get(msg, "content"))

    case msg_type do
      "text" ->
        %{text: Map.get(content, "text", ""), attachments: []}

      "image" ->
        %{
          text: "",
          attachments: [
            attachment(:image, %{
              "file_key" => Map.get(content, "image_key"),
              "name" => "image-" <> short_id(message_id) <> ".jpg",
              "message_id" => message_id,
              "mime" => "image/jpeg"
            })
          ]
        }

      "file" ->
        %{
          text: "",
          attachments: [
            attachment(:file, %{
              "file_key" => Map.get(content, "file_key"),
              "name" => Map.get(content, "file_name", "file-" <> short_id(message_id)),
              "size" => Map.get(content, "file_size"),
              "message_id" => message_id
            })
          ]
        }

      "audio" ->
        %{
          text: "",
          attachments: [
            attachment(:audio, %{
              "file_key" => Map.get(content, "file_key"),
              "name" => "audio-" <> short_id(message_id),
              "duration" => Map.get(content, "duration"),
              "message_id" => message_id
            })
          ]
        }

      "media" ->
        %{
          text: "",
          attachments: [
            attachment(:video, %{
              "file_key" => Map.get(content, "file_key"),
              "name" => "video-" <> short_id(message_id),
              "duration" => Map.get(content, "duration"),
              "message_id" => message_id
            })
          ]
        }

      other ->
        %{
          text:
            "[feishu message_type=#{other} unhandled — content keys: #{inspect(Map.keys(content))}]",
          attachments: []
        }
    end
  end

  defp decode_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp decode_content(_), do: %{}

  defp attachment(type, raw) do
    %{
      type: type,
      source: "feishu",
      file_key: Map.get(raw, "file_key"),
      message_id: Map.get(raw, "message_id"),
      name: Map.get(raw, "name"),
      mime: Map.get(raw, "mime"),
      size_bytes: Map.get(raw, "size"),
      duration: Map.get(raw, "duration")
    }
  end

  defp short_id(nil), do: "unknown"
  defp short_id(s) when is_binary(s), do: String.slice(s, -8, 8)
end
