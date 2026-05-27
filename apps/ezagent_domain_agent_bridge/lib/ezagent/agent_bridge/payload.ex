defmodule Ezagent.AgentBridge.Payload do
  @moduledoc """
  Flavor-neutral envelope from ezagent chat dispatch to an agent bridge.

  Flavor adapters convert this shape to the concrete bridge protocol
  their sidecar expects.
  """

  @enforce_keys [:message_id, :session_uri, :sender_uri, :text, :event_type]
  defstruct [
    :message_id,
    :session_uri,
    :sender_uri,
    :text,
    :event_type,
    attachments: [],
    meta: %{}
  ]

  @type event_type :: :chat_send | :mention_failed | :system

  @type attachment :: %{optional(atom() | String.t()) => term()}

  @type t :: %__MODULE__{
          message_id: String.t(),
          session_uri: URI.t() | nil,
          sender_uri: URI.t(),
          text: String.t(),
          event_type: event_type(),
          attachments: [attachment()],
          meta: %{String.t() => String.t()}
        }
end
