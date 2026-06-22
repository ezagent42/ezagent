import React from "react"
import {Bug, ChevronUp, Maximize2, MessageSquare, Paperclip, Plus, RotateCcw, Route, Send, TerminalSquare, UserPlus, X} from "lucide-react"

import {Button} from "./ui/primitives"
import {PtyTerminalSurface} from "./PtyTerminal"

// Server-rendered attachment: an uploads URI carries a signed download `href`
// (`message_row/2`); any other value renders as a plain label (`href: null`).
type Attachment = {
  name: string
  href?: string | null
}

type MessageRow = {
  id: string
  sender: string
  sender_display?: string | null
  sender_kind?: string | null
  text?: string | null
  attachments?: Attachment[]
  at?: string | null
}

// A file uploaded to the cap-authed endpoint, held until the next send. `grant`
// is the signed attach-token the server verifies before embedding the URI
// (PR-2b anti-laundering). Removing a pending entry IS `cancel_upload` (purely
// client state — the byte is already stored; a future GC reaps unreferenced).
type Pending = {
  id: string
  name: string
  grant: string
}

const MAX_FILE_BYTES = 10 * 1024 * 1024
const MAX_FILES = 5

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

type RoutingRule = {
  id: number
  table?: string | null
  matcher?: string | null
  receivers?: string[]
  receivers_text?: string | null
  source?: string | null
  enabled?: boolean
}

export type ConversationState = {
  active_pty_agent_uri?: string | null
  active_view?: string | null
  agent_detail_path?: string | null
  agent_status?: {phase?: string; flavor?: string; [key: string]: unknown}
  agent_uri?: string | null
  session_uri?: string | null
  caller_uri?: string | null
  messages?: MessageRow[]
  oldest_cursor?: string | null
  pty_alive?: boolean
  pty_initial_buffer?: string
  pty_phase?: string
  routing_rules?: RoutingRule[]
  sessions?: SessionRow[]
  members?: MemberRow[]
}

type Props = {
  state: ConversationState
  onAddRoutingRule: (sessionUri: string, rule: Record<string, string>) => void
  onOpenPty: (sessionUri: string, agent: string) => void
  onRestartOrchestrator: (sessionUri: string) => void
  onSend: (sessionUri: string, text: string, grants: string[]) => void
  onSwitch: (sessionUri: string) => void
  onSwitchView: (sessionUri: string, view: string) => void
  onToggleRoutingRule: (sessionUri: string, rule: {id: string; table: string; enabled: string}) => void
  onLoadOlder: (sessionUri: string, before: string) => void
  onMarkDisplayed: (sessionUri: string, msgId: string) => void
  onInvite: (sessionUri: string, member: string) => void
  onPtyInput: (bytes: string) => void
  onPtyResize: (size: {cols: number; rows: number}) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
}

// The conversation island is keyed by session_uri in `main.tsx`, so a session
// switch (push_patch → handle_params → world:state) remounts it fresh from the
// server-pushed `state.messages`. Within a mount, inbound `chat:message`
// events append (sender sees their OWN cast'd message only via this bridge),
// and `chat:older` prepends history.
export function Conversation({
  state,
  onAddRoutingRule,
  onOpenPty,
  onRestartOrchestrator,
  onSend,
  onSwitch,
  onSwitchView,
  onToggleRoutingRule,
  onLoadOlder,
  onMarkDisplayed,
  onInvite,
  onPtyInput,
  onPtyResize,
  onServerEvent,
}: Props) {
  const sessionUri = state.session_uri || ""
  const callerUri = state.caller_uri || ""
  const sessions = state.sessions || []
  const routingRules = state.routing_rules || []
  const activeView = state.active_view === "pty" ? "pty" : "chat"

  const [members, setMembers] = React.useState<MemberRow[]>(state.members || [])
  const [messages, setMessages] = React.useState<MessageRow[]>(state.messages || [])
  const [oldestCursor, setOldestCursor] = React.useState<string | null>(state.oldest_cursor || null)
  const [text, setText] = React.useState("")
  const [mentionQuery, setMentionQuery] = React.useState<string | null>(null)
  const [pending, setPending] = React.useState<Pending[]>([])
  const [uploadError, setUploadError] = React.useState<string | null>(null)
  const [uploading, setUploading] = React.useState(false)
  const [inviteOpen, setInviteOpen] = React.useState(false)
  const [inviteValue, setInviteValue] = React.useState("")
  const [debugOpen, setDebugOpen] = React.useState(false)
  const [expanded, setExpanded] = React.useState(false)
  const [ruleMatcherType, setRuleMatcherType] = React.useState("always")
  const [ruleMatcherArg, setRuleMatcherArg] = React.useState("")
  const [ruleReceivers, setRuleReceivers] = React.useState("")
  const scrollRef = React.useRef<HTMLDivElement | null>(null)
  const inputRef = React.useRef<HTMLTextAreaElement | null>(null)
  const fileRef = React.useRef<HTMLInputElement | null>(null)
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

  // Upload files to the cap-authed endpoint (parity: chat_compose attachments).
  // Pre-flight validate (parity: validate_compose) before any POST: file count
  // and per-file size are checked client-side for a friendly inline error; the
  // server re-enforces both (never trusts the client).
  const uploadFiles = async (files: File[]) => {
    setUploadError(null)
    if (!sessionUri || files.length === 0) return

    if (pending.length + files.length > MAX_FILES) {
      setUploadError(`At most ${MAX_FILES} attachments per message.`)
      return
    }

    const oversize = files.find((f) => f.size > MAX_FILE_BYTES)
    if (oversize) {
      setUploadError(`"${oversize.name}" exceeds the 10 MB limit.`)
      return
    }

    const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

    setUploading(true)
    try {
      for (const file of files) {
        const form = new FormData()
        form.append("session", sessionUri)
        form.append("file", file)

        const res = await fetch("/world/uploads", {
          method: "POST",
          headers: {"x-csrf-token": csrf},
          body: form,
          credentials: "same-origin",
        })

        if (!res.ok) {
          const body = (await res.json().catch(() => ({}))) as {error?: string}
          setUploadError(body.error || `Upload of "${file.name}" failed (${res.status}).`)
          continue
        }

        const data = (await res.json()) as {name?: string; grant?: string}
        if (data.grant) {
          setPending((cur) => [...cur, {id: `${Date.now()}-${cur.length}`, name: data.name || file.name, grant: data.grant!}])
        }
      }
    } catch (_e) {
      setUploadError("Upload failed — network error.")
    } finally {
      setUploading(false)
      if (fileRef.current) fileRef.current.value = ""
    }
  }

  // cancel_upload parity: drop a pending attachment (client-only).
  const removePending = (id: string) => setPending((cur) => cur.filter((p) => p.id !== id))

  const submit = (event: React.FormEvent) => {
    event.preventDefault()
    const trimmed = text.trim()
    // Parity: a message needs text OR at least one attachment.
    if ((!trimmed && pending.length === 0) || !sessionUri) return
    onSend(sessionUri, trimmed, pending.map((p) => p.grant))
    setText("")
    setPending([])
    setUploadError(null)
  }

  const loadOlder = () => {
    if (oldestCursor && sessionUri) onLoadOlder(sessionUri, oldestCursor)
  }

  const submitRule = (event: React.FormEvent) => {
    event.preventDefault()
    if (!sessionUri) return
    const receivers = ruleReceivers.trim()
    if (!receivers) return
    onAddRoutingRule(sessionUri, {
      matcher_type: ruleMatcherType,
      matcher_arg: ruleMatcherArg.trim(),
      receivers,
    })
    setRuleMatcherType("always")
    setRuleMatcherArg("")
    setRuleReceivers("")
  }

  return (
    <div className="world-conversation-shell" data-world-component="conversation" data-expanded={expanded ? "true" : "false"}>
      <section className="world-section world-conversation">
      <div className="world-section-header">
        <div>
          <p className="world-eyebrow">Session</p>
          <h2>Conversation</h2>
        </div>
        <div className="world-conversation-tools">
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
          <div className="world-segmented" aria-label="Session view">
            <button
              type="button"
              className={activeView === "chat" ? "is-active" : ""}
              onClick={() => sessionUri && onSwitchView(sessionUri, "chat")}
              aria-label="Show chat"
            >
              <MessageSquare aria-hidden="true" />
              Chat
            </button>
            <button
              type="button"
              className={activeView === "pty" ? "is-active" : ""}
              onClick={() => sessionUri && onSwitchView(sessionUri, "pty")}
              aria-label="Show terminal"
            >
              <TerminalSquare aria-hidden="true" />
              PTY
            </button>
          </div>
          <Button type="button" size="sm" variant="secondary" onClick={() => sessionUri && onRestartOrchestrator(sessionUri)} aria-label="Restart orchestrator">
            <RotateCcw aria-hidden="true" />
          </Button>
          <Button type="button" size="sm" variant="secondary" onClick={() => setDebugOpen((open) => !open)} aria-label="Toggle debug panel">
            <Bug aria-hidden="true" />
          </Button>
          <Button type="button" size="sm" variant="secondary" onClick={() => setExpanded((open) => !open)} aria-label="Toggle expanded layout">
            <Maximize2 aria-hidden="true" />
          </Button>
        </div>
      </div>

      {activeView === "pty" ? (
        // Nested PTY = a `:subcomponent` slot (handoff §2): owned and mounted by
        // Conversation, NOT route-mounted and NOT in the layout registry. The
        // `data-world-subcomponent` marker tells the mount gate this is a
        // sanctioned parent-owned mount, not a registry bypass.
        <div data-world-subcomponent="pty_terminal">
          <PtyTerminalSurface
            state={{
              ...state,
              agent_uri: state.agent_uri || state.active_pty_agent_uri || null,
            }}
            onInput={onPtyInput}
            onResize={onPtyResize}
            onServerEvent={onServerEvent}
          />
        </div>
      ) : (
      <>
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
                      <li key={`${message.id}-att-${index}`}>
                        {attachment.href ? (
                          <a href={attachment.href} className="world-attachment-link">
                            <Paperclip aria-hidden="true" />
                            {attachment.name}
                          </a>
                        ) : (
                          attachment.name
                        )}
                      </li>
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
          {pending.length > 0 && (
            <ul className="world-composer-chips" aria-label="Pending attachments">
              {pending.map((p) => (
                <li key={p.id} className="world-composer-chip">
                  <Paperclip aria-hidden="true" />
                  <span className="world-composer-chip-name">{p.name}</span>
                  <button
                    type="button"
                    className="world-composer-chip-remove"
                    aria-label={`Remove ${p.name}`}
                    onClick={() => removePending(p.id)}
                  >
                    <X aria-hidden="true" />
                  </button>
                </li>
              ))}
            </ul>
          )}
          {uploadError && <p className="world-composer-error" role="alert">{uploadError}</p>}
        </div>
        <div className="world-composer-actions">
          <input
            ref={fileRef}
            type="file"
            multiple
            className="world-composer-file"
            onChange={(event) => uploadFiles(Array.from(event.target.files || []))}
            aria-hidden="true"
            tabIndex={-1}
          />
          <Button
            type="button"
            size="sm"
            variant="secondary"
            disabled={uploading || pending.length >= MAX_FILES}
            onClick={() => fileRef.current?.click()}
            aria-label="Attach files"
          >
            <Paperclip aria-hidden="true" />
          </Button>
          <Button type="submit" size="sm" disabled={uploading || (!text.trim() && pending.length === 0)}>
            <Send aria-hidden="true" />
            Send
          </Button>
        </div>
        </form>
      </>
      )}

      {debugOpen && (
        <pre className="world-debug-panel">{JSON.stringify({sessionUri, activeView, members: members.length, messages: messages.length}, null, 2)}</pre>
      )}
      </section>

      <aside className="world-section world-members" aria-label="Session members">
        <div className="world-section-header world-section-header-compact">
          <div>
            <p className="world-eyebrow">Members</p>
            <h2>{members.length}</h2>
          </div>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => setInviteOpen(true)}
            aria-label="Invite a member"
          >
            <UserPlus aria-hidden="true" />
            Invite
          </Button>
        </div>
        {inviteOpen && (
          <form
            className="world-invite"
            onSubmit={(event) => {
              event.preventDefault()
              const member = inviteValue.trim()
              if (!member || !sessionUri) return
              onInvite(sessionUri, member)
              setInviteValue("")
              setInviteOpen(false)
            }}
          >
            <label className="world-invite-label" htmlFor="world-invite-input">
              Invite by entity URI
            </label>
            <input
              id="world-invite-input"
              className="world-invite-input"
              value={inviteValue}
              onChange={(event) => setInviteValue(event.target.value)}
              placeholder="entity://workspace/user/name"
              autoFocus
            />
            <div className="world-invite-actions">
              <Button type="submit" size="sm" disabled={!inviteValue.trim()}>
                Invite
              </Button>
              <Button
                type="button"
                size="sm"
                variant="secondary"
                onClick={() => {
                  setInviteOpen(false)
                  setInviteValue("")
                }}
              >
                Cancel
              </Button>
            </div>
          </form>
        )}
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
                {member.kind === "agent" && (
                  <Button type="button" size="sm" variant="secondary" onClick={() => sessionUri && onOpenPty(sessionUri, member.uri)} aria-label={`Open terminal for ${member.display_name || member.uri}`}>
                    <TerminalSquare aria-hidden="true" />
                  </Button>
                )}
              </li>
            ))
          )}
        </ul>

        <div className="world-routing-panel">
          <div className="world-section-header world-section-header-compact">
            <div>
              <p className="world-eyebrow">Routing</p>
              <h2>{routingRules.length}</h2>
            </div>
            <Route aria-hidden="true" />
          </div>
          <form className="world-routing-form" id="world-session-routing-form" onSubmit={submitRule}>
            <select value={ruleMatcherType} onChange={(event) => setRuleMatcherType(event.target.value)} aria-label="Matcher type">
              <option value="always">Always</option>
              <option value="mention">Mention</option>
              <option value="from">From</option>
              <option value="text_contains">Text contains</option>
            </select>
            <input
              value={ruleMatcherArg}
              onChange={(event) => setRuleMatcherArg(event.target.value)}
              placeholder={ruleMatcherType === "always" ? "No matcher argument" : "matcher argument"}
              disabled={ruleMatcherType === "always"}
              aria-label="Matcher argument"
            />
            <input
              value={ruleReceivers}
              onChange={(event) => setRuleReceivers(event.target.value)}
              placeholder="entity://system/user/admin"
              aria-label="Receivers"
            />
            <Button type="submit" size="sm" disabled={!ruleReceivers.trim()}>
              <Plus aria-hidden="true" />
              Add
            </Button>
          </form>
          <ul className="world-routing-list">
            {routingRules.length === 0 ? (
              <li className="world-routing-empty">No session routing rules.</li>
            ) : (
              routingRules.map((rule) => (
                <li key={`${rule.table}-${rule.id}`} className="world-routing-rule" data-enabled={rule.enabled ? "true" : "false"}>
                  <div>
                    <strong>{rule.matcher || `Rule ${rule.id}`}</strong>
                    <span>{rule.receivers_text || (rule.receivers || []).join(", ")}</span>
                  </div>
                  <Button
                    type="button"
                    size="sm"
                    variant="secondary"
                    onClick={() =>
                      sessionUri &&
                      onToggleRoutingRule(sessionUri, {
                        id: String(rule.id),
                        table: rule.table || "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
                        enabled: rule.enabled ? "true" : "false",
                      })
                    }
                  >
                    {rule.enabled ? "Disable" : "Enable"}
                  </Button>
                </li>
              ))
            )}
          </ul>
        </div>
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
