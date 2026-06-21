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

type MemberRow = {
  uri: string
  display_name?: string | null
  online?: boolean
  kind?: string | null
}

export type ConversationState = {
  session_uri?: string | null
  caller_uri?: string | null
  messages?: MessageRow[]
  oldest_cursor?: string | null
  sessions?: SessionRow[]
  members?: MemberRow[]
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

  const [members, setMembers] = React.useState<MemberRow[]>(state.members || [])
  const [messages, setMessages] = React.useState<MessageRow[]>(state.messages || [])
  const [oldestCursor, setOldestCursor] = React.useState<string | null>(state.oldest_cursor || null)
  const [text, setText] = React.useState("")
  const [mentionQuery, setMentionQuery] = React.useState<string | null>(null)
  const scrollRef = React.useRef<HTMLDivElement | null>(null)
  const inputRef = React.useRef<HTMLTextAreaElement | null>(null)
  const markedRef = React.useRef<Set<string>>(new Set())

  // @mention autocomplete: the open token is the @word immediately before the
  // caret. Inserting the member's URI path segment keeps it a single bare
  // token the server-side parser resolves (display names may contain spaces).
  const mentionMatches = React.useMemo(() => {
    if (mentionQuery === null) return []
    const q = mentionQuery.toLowerCase()
    return members
      .filter((m) => {
        const seg = uriSegment(m.uri).toLowerCase()
        const name = (m.display_name || "").toLowerCase()
        return q === "" || seg.includes(q) || name.includes(q)
      })
      .slice(0, 6)
  }, [mentionQuery, members])

  const onComposerChange = (value: string, caret: number) => {
    setText(value)
    const upto = value.slice(0, caret)
    const m = upto.match(/(?:^|[^\p{L}\p{N}_])@([A-Za-z0-9._-]*)$/u)
    setMentionQuery(m ? m[1] : null)
  }

  const insertMention = (member: MemberRow) => {
    const el = inputRef.current
    const caret = el ? el.selectionStart : text.length
    const upto = text.slice(0, caret)
    const rest = text.slice(caret)
    const replaced = upto.replace(/@([A-Za-z0-9._-]*)$/u, `@${uriSegment(member.uri)} `)
    const next = replaced + rest
    setText(next)
    setMentionQuery(null)
    requestAnimationFrame(() => {
      if (!el) return
      el.focus()
      const pos = replaced.length
      el.setSelectionRange(pos, pos)
    })
  }

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

    onServerEvent("members:update", (payload) => {
      const next = payload as {members?: MemberRow[]}
      if (next.members) setMembers(next.members)
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
    <div className="world-conversation-shell" data-world-component="conversation">
      <section className="world-section world-conversation">
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
          <p className="world-conversation-empty">
            No turns in this session yet. Send the first message to start the transcript.
          </p>
        ) : (
          messages.map((message) => {
            const mine = message.sender === callerUri
            const kind = message.sender_kind || "other"
            return (
              <div
                key={message.id}
                className="world-message"
                data-msg-id={message.id}
                data-sender-kind={kind}
                data-mine={mine ? "true" : "false"}
              >
                <span className="world-message-kind">{kindLabel(kind, mine)}</span>
                <div className="world-message-head">
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
        <div className="world-composer-field">
          {mentionMatches.length > 0 && (
            <ul className="world-mention-menu" role="listbox" aria-label="Mention a member">
              {mentionMatches.map((member) => (
                <li key={member.uri}>
                  <button
                    type="button"
                    className="world-mention-option"
                    onMouseDown={(event) => {
                      // mousedown (not click) so the textarea doesn't blur first
                      event.preventDefault()
                      insertMention(member)
                    }}
                  >
                    <span className="world-mention-handle">@{uriSegment(member.uri)}</span>
                    {member.display_name && member.display_name !== uriSegment(member.uri) && (
                      <span className="world-mention-name">{member.display_name}</span>
                    )}
                  </button>
                </li>
              ))}
            </ul>
          )}
          <textarea
            ref={inputRef}
            className="world-composer-input"
            value={text}
            onChange={(event) => onComposerChange(event.target.value, event.target.selectionStart)}
            onKeyDown={(event) => {
              if (event.key === "Escape" && mentionQuery !== null) {
                setMentionQuery(null)
                return
              }
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault()
                submit(event)
              }
            }}
            placeholder="Type a message…  @ to mention"
            rows={2}
            aria-label="Message"
          />
        </div>
        <Button type="submit" size="sm" disabled={!text.trim()}>
          <Send aria-hidden="true" />
          Send
        </Button>
      </form>
      </section>

      <aside className="world-section world-members" aria-label="Session members">
        <div className="world-section-header world-section-header-compact">
          <div>
            <p className="world-eyebrow">Members</p>
            <h2>{members.length}</h2>
          </div>
        </div>
        <ul className="world-members-list">
          {members.length === 0 ? (
            <li className="world-members-empty">No members yet.</li>
          ) : (
            members.map((member) => (
              <li
                key={member.uri}
                className="world-member"
                data-kind={member.kind || "other"}
                data-online={member.online ? "true" : "false"}
              >
                <span
                  className="world-member-dot"
                  data-online={member.online ? "true" : "false"}
                  aria-hidden="true"
                />
                <span className="world-member-name">{member.display_name || member.uri}</span>
                <span className="world-member-kind">{member.kind || "other"}</span>
              </li>
            ))
          )}
        </ul>
      </aside>
    </div>
  )
}

function formatAt(at: string) {
  const date = new Date(at)
  if (Number.isNaN(date.getTime())) return at
  return date.toLocaleString()
}

// Last path segment of an entity URI (e.g. entity://system/agent/codex-1 →
// "codex-1") — a clean single token the server-side mention parser resolves.
function uriSegment(uri: string) {
  const noQuery = uri.split(/[?#]/)[0]
  const parts = noQuery.split("/").filter(Boolean)
  return parts[parts.length - 1] || uri
}

// Runtime kind-tag — the viewer's own turns read "YOU"; agents and other
// humans carry their participant class so the transcript shows at a glance
// who is a person and who is an agent.
function kindLabel(kind: string, mine: boolean) {
  if (mine) return "You"
  if (kind === "agent") return "Agent"
  if (kind === "user") return "User"
  return "Participant"
}
