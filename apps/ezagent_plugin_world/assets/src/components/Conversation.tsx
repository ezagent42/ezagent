import React from "react"
import {ChevronUp, Send} from "lucide-react"

import {Button} from "./ui/primitives"

type MessageRow = {
  id: string
  sender: string
  sender_display?: string | null
  sender_kind?: string | null
  text?: string | null
  attachments?: string[]
  at?: string | null
}

type SessionRow = {
  uri: string
  name?: string | null
}

export type ConversationState = {
  session_uri?: string | null
  caller_uri?: string | null
  messages?: MessageRow[]
  oldest_cursor?: string | null
  sessions?: SessionRow[]
}

type Props = {
  state: ConversationState
  onSend: (sessionUri: string, text: string) => void
  onSwitch: (sessionUri: string) => void
  onLoadOlder: (sessionUri: string, before: string) => void
  onMarkDisplayed: (sessionUri: string, msgId: string) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
}

// The conversation island is keyed by session_uri in `main.tsx`, so a session
// switch (push_patch → handle_params → world:state) remounts it fresh from the
// server-pushed `state.messages`. Within a mount, inbound `chat:message`
// events append (sender sees their OWN cast'd message only via this bridge),
// and `chat:older` prepends history.
export function Conversation({state, onSend, onSwitch, onLoadOlder, onMarkDisplayed, onServerEvent}: Props) {
  const sessionUri = state.session_uri || ""
  const callerUri = state.caller_uri || ""
  const sessions = state.sessions || []

  const [messages, setMessages] = React.useState<MessageRow[]>(state.messages || [])
  const [oldestCursor, setOldestCursor] = React.useState<string | null>(state.oldest_cursor || null)
  const [text, setText] = React.useState("")
  const scrollRef = React.useRef<HTMLDivElement | null>(null)
  const markedRef = React.useRef<Set<string>>(new Set())

  React.useEffect(() => {
    if (!onServerEvent) return undefined

    onServerEvent("chat:message", (payload) => {
      const {message} = payload as {message?: MessageRow}
      if (!message) return
      setMessages((current) => (current.some((m) => m.id === message.id) ? current : [...current, message]))
    })

    onServerEvent("chat:older", (payload) => {
      const batch = payload as {messages?: MessageRow[]; oldest_cursor?: string | null}
      if (!batch.messages?.length) return
      setMessages((current) => {
        const seen = new Set(current.map((m) => m.id))
        const fresh = batch.messages!.filter((m) => !seen.has(m.id))
        return [...fresh, ...current]
      })
      setOldestCursor(batch.oldest_cursor ?? null)
    })

    return undefined
  }, [onServerEvent])

  // Keep the viewport pinned to the newest message as the stream grows.
  React.useEffect(() => {
    const el = scrollRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [messages.length])

  // Fire-and-forget read markers — once per message id (parity:
  // mark_displayed). A full viewport-intersection model can refine this in
  // a later PR; PR-1 marks every loaded message as displayed exactly once.
  React.useEffect(() => {
    if (!sessionUri) return
    for (const message of messages) {
      if (!markedRef.current.has(message.id)) {
        markedRef.current.add(message.id)
        onMarkDisplayed(sessionUri, message.id)
      }
    }
  }, [messages, sessionUri, onMarkDisplayed])

  const submit = (event: React.FormEvent) => {
    event.preventDefault()
    const trimmed = text.trim()
    if (!trimmed || !sessionUri) return
    onSend(sessionUri, trimmed)
    setText("")
  }

  const loadOlder = () => {
    if (oldestCursor && sessionUri) onLoadOlder(sessionUri, oldestCursor)
  }

  return (
    <section className="world-section world-conversation" data-world-component="conversation">
      <div className="world-section-header">
        <div>
          <p className="world-eyebrow">Session</p>
          <h2>Conversation</h2>
        </div>
        {sessions.length > 1 && (
          <select
            className="world-session-select"
            value={sessionUri}
            onChange={(event) => onSwitch(event.target.value)}
            aria-label="Switch session"
          >
            {sessions.map((session) => (
              <option key={session.uri} value={session.uri}>
                {session.name || session.uri}
              </option>
            ))}
          </select>
        )}
      </div>

      <div className="world-conversation-stream" ref={scrollRef} data-message-count={messages.length}>
        {oldestCursor && (
          <div className="world-conversation-older">
            <Button size="sm" variant="secondary" onClick={loadOlder}>
              <ChevronUp aria-hidden="true" />
              Load older
            </Button>
          </div>
        )}

        {messages.length === 0 ? (
          <p className="world-empty">No messages yet. Say something to start the conversation.</p>
        ) : (
          messages.map((message) => {
            const mine = message.sender === callerUri
            return (
              <div
                key={message.id}
                className="world-message"
                data-msg-id={message.id}
                data-sender-kind={message.sender_kind || "other"}
                data-mine={mine ? "true" : "false"}
              >
                <div className="world-message-meta">
                  <span className="world-message-sender">{message.sender_display || message.sender}</span>
                  {message.at && <span className="world-message-at">{formatAt(message.at)}</span>}
                </div>
                {message.text && <p className="world-message-text">{message.text}</p>}
                {message.attachments && message.attachments.length > 0 && (
                  <ul className="world-message-attachments">
                    {message.attachments.map((attachment, index) => (
                      <li key={`${message.id}-att-${index}`}>{attachment}</li>
                    ))}
                  </ul>
                )}
              </div>
            )
          })
        )}
      </div>

      <form className="world-composer" onSubmit={submit}>
        <textarea
          className="world-composer-input"
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault()
              submit(event)
            }
          }}
          placeholder="Type a message…"
          rows={2}
          aria-label="Message"
        />
        <Button type="submit" size="sm" disabled={!text.trim()}>
          <Send aria-hidden="true" />
          Send
        </Button>
      </form>
    </section>
  )
}

function formatAt(at: string) {
  const date = new Date(at)
  if (Number.isNaN(date.getTime())) return at
  return date.toLocaleString()
}
