import React from "react"
import {Bug, CheckCircle2, ChevronUp, Copy, ExternalLink, Maximize2, MessageSquare, Paperclip, Plus, RotateCcw, Route, Send, TerminalSquare, Upload, UserMinus, UserPlus, X} from "lucide-react"

import {Button, Modal} from "./ui/primitives"
import {PtyTerminalSurface} from "./PtyTerminal"
import {JsonRenderBubble} from "./JsonRenderBubble"

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
  // Optional json-render node tree — a table/card shown inline in the bubble.
  render?: unknown
  // Optional per-card CSS theme (a user's explicit style ask), scoped to the card.
  render_css?: string | null
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
  role_name?: string | null
}

type HumanRoleSlot = {
  role_name: string
  assigned_uri?: string | null
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
  is_hello?: boolean | null
  messages?: MessageRow[]
  oldest_cursor?: string | null
  pty_alive?: boolean
  pty_initial_buffer?: string
  pty_phase?: string
  routing_rules?: RoutingRule[]
  sessions?: SessionRow[]
  members?: MemberRow[]
  human_role_slots?: HumanRoleSlot[]
}

type Props = {
  state: ConversationState
  onAddRoutingRule: (sessionUri: string, rule: Record<string, string>) => void
  onForkConfig: (sessionUri: string) => void
  onOpenPty: (sessionUri: string, agent: string) => void
  onRestartOrchestrator: (sessionUri: string) => void
  onSend: (sessionUri: string, text: string, grants: string[]) => void
  onSwitch: (sessionUri: string) => void
  onSwitchView: (sessionUri: string, view: string) => void
  onToggleRoutingRule: (sessionUri: string, rule: {id: string; table: string; enabled: string}) => void
  onLoadOlder: (sessionUri: string, before: string) => void
  onMarkDisplayed: (sessionUri: string, msgId: string) => void
  onInvite: (sessionUri: string, member: string) => void
  onAssignRole: (sessionUri: string, member: string, roleName: string) => void
  onRemoveParticipant: (sessionUri: string, participant: string) => void
  onPtyInput: (bytes: string) => void
  onPtyResize: (size: {cols: number; rows: number}) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
  // Publish this (hello) session as a reusable SessionTemplate carrying the
  // current page + agent (not the chat history). Operator-only; the button lives
  // in the page-preview overlay, so it never shows on the public share page.
  onPublishTemplate: (sessionUri: string, name: string) => void
}

// The conversation island is keyed by session_uri in `main.tsx`, so a session
// switch (push_patch → handle_params → world:state) remounts it fresh from the
// server-pushed `state.messages`. Within a mount, inbound `chat:message`
// events append (sender sees their OWN cast'd message only via this bridge),
// and `chat:older` prepends history.
export function Conversation({
  state,
  onAddRoutingRule,
  onForkConfig,
  onOpenPty,
  onAssignRole,
  onRemoveParticipant,
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
  onPublishTemplate,
}: Props) {
  const sessionUri = state.session_uri || ""
  const callerUri = state.caller_uri || ""
  const sessions = state.sessions || []
  const routingRules = state.routing_rules || []
  const activeView = state.active_view === "pty" ? "pty" : "chat"
  // TEMPORARY (hello internal view): only hello sessions get a Page tab. The
  // proper home for this is world surfacing registered SessionViews (Phase 3);
  // for now it embeds the external surface. See HelloPagePreview below.
  // Server-detected (has a `:surface` slice) so a session from a PUBLISHED hello
  // template — whose URI carries the template name, not `/hello/` — still gets the
  // Page pane. Falls back to the URI check.
  const isHelloSession = state.is_hello === true || sessionUri.includes("/hello/")

  const [members, setMembers] = React.useState<MemberRow[]>(state.members || [])
  const [humanRoleSlots, setHumanRoleSlots] = React.useState<HumanRoleSlot[]>(state.human_role_slots || [])
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
  const openHumanRoles = React.useMemo(
    () => humanRoleSlots.filter((slot) => !slot.assigned_uri),
    [humanRoleSlots],
  )

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
      const next = payload as {members?: MemberRow[]; human_role_slots?: HumanRoleSlot[]}
      if (next.members) setMembers(next.members)
      if (next.human_role_slots) setHumanRoleSlots(next.human_role_slots)
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
    <div
      className="grid h-full min-h-0 overflow-hidden border border-border bg-card shadow-[var(--shadow-card)] lg:grid-cols-[276px_minmax(430px,1fr)_260px]"
      data-world-component="conversation"
      data-world-chat-layout="im"
      data-expanded={expanded ? "true" : "false"}
    >
      <aside
        className="hidden min-h-0 flex-col overflow-hidden border-r border-border bg-[#fafafa] text-card-foreground lg:flex"
        aria-label="Sessions"
        data-world-session-rail
      >
        <div className="flex min-h-[58px] items-center justify-between gap-2.5 border-b border-border px-3 py-2.5">
          <div>
            <h2 className="text-[13px] font-bold text-foreground">Sessions</h2>
            <p className="mt-0.5 text-[11px] text-muted-foreground">Current workspace only</p>
          </div>
          <Button size="sm" variant="secondary" aria-label="Create a new session">
            <Plus aria-hidden="true" />
          </Button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto p-2.5">
          <div className="mb-2 min-h-[34px] rounded-[10px] border border-border bg-muted px-2.5 py-2 text-[12px] text-muted-foreground">
            Filter sessions, template, status
          </div>
          {sessions.length === 0 ? (
            <p className="px-2 py-3 text-[13px] leading-relaxed text-muted-foreground">No sessions in this workspace.</p>
          ) : (
            <ul className="m-0 flex list-none flex-col gap-2 p-0">
              {sessions.map((session) => {
                const active = session.uri === sessionUri
                const label = session.name || uriSegment(session.uri)

                return (
                  <li key={session.uri}>
                    <button
                      type="button"
                      aria-current={active ? "page" : undefined}
                      onClick={() => onSwitch(session.uri)}
                      className={
                        active
                          ? "flex w-full min-w-0 items-start gap-2 rounded-[10px] border border-[#f0d44a] bg-[#fff2a6] px-2.5 py-2.5 text-left text-foreground"
                          : "flex w-full min-w-0 items-start gap-2 rounded-[10px] border border-border bg-card px-2.5 py-2.5 text-left text-muted-foreground transition hover:border-primary hover:text-foreground"
                      }
                    >
                      <MessageSquare aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-[13px] font-semibold">{label}</span>
                        <span className="mt-0.5 block truncate font-mono text-[11px] opacity-75" title={session.uri}>
                          {session.uri}
                        </span>
                      </span>
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      </aside>

      <section className="flex min-h-0 flex-col overflow-hidden bg-card text-card-foreground">
        <div
          data-world-session-header
          className="flex min-h-[58px] flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-3 sm:flex-nowrap sm:items-center"
        >
          <div className="min-w-0 flex-1">
            <h2 className="text-[13px] font-bold text-foreground">{sessionUri ? uriSegment(sessionUri) : "Conversation"}</h2>
            <p className="mt-0.5 max-w-[48ch] truncate font-mono text-[11px] text-muted-foreground">{sessionUri || "No active session"}</p>
          </div>
          <div
            data-world-session-toolbar
            className="flex w-full min-w-0 flex-wrap items-center justify-start gap-2 sm:w-auto sm:justify-end"
          >
            {sessions.length > 1 && (
              <select
                className="max-w-[280px] rounded-md border border-border bg-card px-2.5 py-1.5 text-[13px] text-foreground lg:hidden"
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
            <div className="inline-flex items-center rounded-[10px] border border-border bg-muted p-[3px]" aria-label="Session view">
              <button type="button" className={segmentClass(activeView === "chat")} onClick={() => sessionUri && onSwitchView(sessionUri, "chat")} aria-label="Show chat">
                <MessageSquare aria-hidden="true" className="h-[15px] w-[15px]" />
                Chat
              </button>
              <button type="button" className={segmentClass(activeView === "pty")} onClick={() => sessionUri && onSwitchView(sessionUri, "pty")} aria-label="Show terminal">
                <TerminalSquare aria-hidden="true" className="h-[15px] w-[15px]" />
                PTY
              </button>
            </div>
            <Button type="button" size="sm" variant="secondary" onClick={() => sessionUri && onForkConfig(sessionUri)} aria-label="复制配置，建新会话" title="复制配置，建新会话">
              <Copy aria-hidden="true" />
            </Button>
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
          <div className="flex min-h-0 flex-1 overflow-hidden">
            <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
            <div
              className="flex flex-1 flex-col gap-3.5 overflow-y-auto bg-[linear-gradient(#ffffff,#ffffff),repeating-linear-gradient(0deg,transparent,transparent_31px,rgba(23,32,42,0.04)_32px)] px-4 py-4"
              ref={scrollRef}
              data-message-count={messages.length}
            >
              {oldestCursor && (
                <div className="flex justify-center pb-0.5">
                  <Button size="sm" variant="secondary" onClick={loadOlder}>
                    <ChevronUp aria-hidden="true" />
                    Load older
                  </Button>
                </div>
              )}

              {messages.length === 0 ? (
                <p className="m-auto max-w-[38ch] text-center text-[13.5px] leading-relaxed text-muted-foreground">
                  No turns in this session yet. Send the first message to start the transcript.
                </p>
              ) : (
                messages.map((message) => {
                  const mine = message.sender === callerUri
                  const kind = message.sender_kind || "other"
                  return (
                    <div
                      key={message.id}
                      className={bubbleClass(mine, kind)}
                      data-msg-id={message.id}
                      data-sender-kind={kind}
                      data-mine={mine ? "true" : "false"}
                    >
                      <span className={bubbleKindClass(mine, kind)}>{kindLabel(kind, mine)}</span>
                      <div className="flex items-baseline justify-between gap-3.5">
                        <span className={mine ? "text-[12.5px] font-semibold text-primary-foreground" : "text-[12.5px] font-semibold text-foreground"}>
                          {message.sender_display || message.sender}
                        </span>
                        {message.at && (
                          <span className={mine ? "whitespace-nowrap text-[11px] tabular-nums text-primary-foreground/80" : "whitespace-nowrap text-[11px] tabular-nums text-muted-foreground"}>
                            {formatAt(message.at)}
                          </span>
                        )}
                      </div>
                      {message.text && <p className={bubbleTextClass(mine, kind)}>{message.text}</p>}
                      {message.render && typeof message.render === "object" && (
                        <JsonRenderBubble
                          spec={message.render}
                          css={message.render_css}
                          onSend={(t) => onSend(sessionUri, t, [])}
                        />
                      )}
                      {message.attachments && message.attachments.length > 0 && (
                        <ul className="m-0 mt-0.5 flex list-none flex-wrap gap-1.5 p-0">
                          {message.attachments.map((attachment, index) => (
                            <li
                              key={`${message.id}-att-${index}`}
                              className={mine ? "rounded-full bg-white/20 px-1.5 py-0.5 font-mono text-[11px]" : "rounded-full bg-foreground/[0.06] px-1.5 py-0.5 font-mono text-[11px]"}
                            >
                              {attachment.href ? (
                                <a href={attachment.href} className="inline-flex items-center gap-1 underline underline-offset-2">
                                  <Paperclip aria-hidden="true" className="h-3 w-3" />
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

            <form className="flex items-end gap-2.5 border-t border-border bg-[#fafafa] px-4 py-3" onSubmit={submit}>
              <div className="relative flex-1">
                {mentionMatches.length > 0 && (
                  <ul className="absolute bottom-[calc(100%+6px)] left-0 right-0 z-20 m-0 max-h-[220px] list-none overflow-y-auto rounded-lg border border-border bg-card p-1 shadow-xl" role="listbox" aria-label="Mention a member">
                    {mentionMatches.map((member) => (
                      <li key={member.uri}>
                        <button
                          type="button"
                          className="flex w-full items-baseline gap-2 rounded-md px-2.5 py-1.5 text-left text-foreground hover:bg-muted"
                          onMouseDown={(event) => {
                            // mousedown (not click) so the textarea doesn't blur first
                            event.preventDefault()
                            insertMention(member)
                          }}
                        >
                          <span className="font-mono text-[12.5px] font-semibold text-emerald-700 dark:text-emerald-300">@{uriSegment(member.uri)}</span>
                          {member.display_name && member.display_name !== uriSegment(member.uri) && (
                            <span className="text-xs text-muted-foreground">{member.display_name}</span>
                          )}
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
                <textarea
                  ref={inputRef}
                  className="max-h-[180px] min-h-[58px] w-full resize-y rounded-[10px] border border-input bg-card px-3 py-2.5 text-sm leading-relaxed text-foreground outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30"
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
                  <ul className="m-0 mt-2 flex list-none flex-wrap gap-1.5 p-0" aria-label="Pending attachments">
                    {pending.map((p) => (
                      <li key={p.id} className="inline-flex items-center gap-1.5 rounded-full bg-foreground/[0.06] py-0.5 pl-2 pr-1.5 text-xs text-foreground">
                        <Paperclip aria-hidden="true" className="h-3 w-3" />
                        <span className="max-w-[18ch] overflow-hidden text-ellipsis whitespace-nowrap">{p.name}</span>
                        <button
                          type="button"
                          className="inline-flex rounded-full p-0.5 text-muted-foreground hover:bg-foreground/10 hover:text-foreground"
                          aria-label={`Remove ${p.name}`}
                          onClick={() => removePending(p.id)}
                        >
                          <X aria-hidden="true" className="h-3 w-3" />
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
                {uploadError && <p className="m-0 mt-1.5 text-xs text-destructive" role="alert">{uploadError}</p>}
              </div>
              <div className="flex items-end gap-2">
                <input
                  ref={fileRef}
                  type="file"
                  multiple
                  className="hidden"
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
            </div>
            {isHelloSession && (
              <div className="hidden min-w-0 flex-1 border-l border-border lg:flex lg:flex-col">
                <HelloPagePreview sessionUri={sessionUri} onPublishTemplate={onPublishTemplate} />
              </div>
            )}
          </div>
        )}

        {debugOpen && (
          <pre className="m-0 overflow-auto border-t border-border bg-[#111827] px-4 py-3 font-mono text-xs text-[#d1d5db]">
            {JSON.stringify({sessionUri, activeView, members: members.length, messages: messages.length}, null, 2)}
          </pre>
        )}
      </section>

      <aside className="flex min-h-0 flex-col overflow-hidden border-l border-border bg-[#fafafa] text-card-foreground" aria-label="Session members">
        <div className="flex min-h-[58px] items-start justify-between gap-2.5 border-b border-border px-4 py-3">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Members</p>
            <h2 className="text-[17px] font-semibold text-foreground">{members.length}</h2>
          </div>
          <Button size="sm" variant="secondary" onClick={() => setInviteOpen(true)} aria-label="Invite a member">
            <UserPlus aria-hidden="true" />
            Invite
          </Button>
        </div>
        {inviteOpen && (
          <form
            className="flex flex-col gap-2 border-b border-border px-4 py-2.5"
            onSubmit={(event) => {
              event.preventDefault()
              const member = inviteValue.trim()
              if (!member || !sessionUri) return
              onInvite(sessionUri, member)
              setInviteValue("")
              setInviteOpen(false)
            }}
          >
            <label className="text-[11px] text-muted-foreground" htmlFor="world-invite-input">
              Invite by entity URI
            </label>
            <input
              id="world-invite-input"
              className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 font-mono text-xs text-foreground"
              value={inviteValue}
              onChange={(event) => setInviteValue(event.target.value)}
              placeholder="entity://workspace/user/name"
              autoFocus
            />
            <div className="flex gap-2">
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
        <ul className="m-0 flex list-none flex-col gap-0.5 overflow-y-auto p-2">
          {members.length === 0 ? (
            <li className="px-2 py-2.5 text-[13px] text-muted-foreground">No members yet.</li>
          ) : (
            members.map((member) => (
              <li
                key={member.uri}
                className="flex items-center gap-2.5 rounded-md px-2.5 py-1.5 hover:bg-muted"
                data-kind={member.kind || "other"}
                data-online={member.online ? "true" : "false"}
              >
                <span
                  className={
                    member.online
                      ? "h-2 w-2 flex-none rounded-full bg-green-600 shadow-[0_0_0_3px_rgba(22,163,74,0.16)]"
                      : "h-2 w-2 flex-none rounded-full bg-border"
                  }
                  aria-hidden="true"
                />
                <span
                  className={
                    member.kind === "agent"
                      ? "min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap font-mono text-xs text-foreground"
                      : "min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[13px] text-foreground"
                  }
                >
                  {member.display_name || member.uri}
                </span>
                <span className="font-mono text-[9.5px] font-semibold uppercase tracking-wide text-muted-foreground">{member.kind || "other"}</span>
                {member.role_name ? (
                  <span className="rounded border border-border bg-background px-1.5 py-0.5 text-[10px] font-semibold text-foreground">
                    {member.role_name}
                  </span>
                ) : (
                  member.kind === "user" &&
                  openHumanRoles.length > 0 && (
                    <select
                      className="h-7 max-w-[126px] rounded-md border border-border bg-background px-2 text-[11px] text-foreground"
                      aria-label={`Assign role to ${member.display_name || member.uri}`}
                      value=""
                      onChange={(event) => {
                        if (event.target.value && sessionUri) onAssignRole(sessionUri, member.uri, event.target.value)
                      }}
                    >
                      <option value="">Role</option>
                      {openHumanRoles.map((slot) => (
                        <option key={slot.role_name} value={slot.role_name}>
                          {slot.role_name}
                        </option>
                      ))}
                    </select>
                  )
                )}
                {member.kind === "agent" && (
                  <Button type="button" size="sm" variant="secondary" onClick={() => sessionUri && onOpenPty(sessionUri, member.uri)} aria-label={`Open terminal for ${member.display_name || member.uri}`}>
                    <TerminalSquare aria-hidden="true" />
                  </Button>
                )}
                {/* F7 PR-A — re-instate the per-member remove control (the QA-pulled
                    one). Cap-gated server-side: only the session owner (or the
                    member itself) is authorized; an unauthorized click degrades to
                    an error status and the member stays. */}
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  onClick={() => sessionUri && onRemoveParticipant(sessionUri, member.uri)}
                  aria-label={`Remove ${member.display_name || member.uri}`}
                  title="Remove from session"
                >
                  <UserMinus aria-hidden="true" />
                </Button>
              </li>
            ))
          )}
        </ul>

        <div className="border-t border-border pt-3">
          <div className="flex items-start justify-between gap-2.5 px-4 pb-1">
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Routing</p>
              <h2 className="text-[17px] font-semibold text-foreground">{routingRules.length}</h2>
            </div>
            <Route aria-hidden="true" className="h-[15px] w-[15px] text-muted-foreground" />
          </div>
          <form className="grid grid-cols-[minmax(0,0.9fr)_minmax(0,1fr)] gap-2 p-2" id="world-session-routing-form" onSubmit={submitRule}>
            <select className={routingFieldClass} value={ruleMatcherType} onChange={(event) => setRuleMatcherType(event.target.value)} aria-label="Matcher type">
              <option value="always">Always</option>
              <option value="mention">Mention</option>
              <option value="from">From</option>
              <option value="text_contains">Text contains</option>
            </select>
            <input
              className={routingFieldClass}
              value={ruleMatcherArg}
              onChange={(event) => setRuleMatcherArg(event.target.value)}
              placeholder={ruleMatcherType === "always" ? "No matcher argument" : "matcher argument"}
              disabled={ruleMatcherType === "always"}
              aria-label="Matcher argument"
            />
            <input
              className={`${routingFieldClass} col-span-2`}
              value={ruleReceivers}
              onChange={(event) => setRuleReceivers(event.target.value)}
              placeholder="entity://system/user/admin"
              aria-label="Receivers"
            />
            <div className="col-span-2">
              <Button type="submit" size="sm" disabled={!ruleReceivers.trim()}>
                <Plus aria-hidden="true" />
                Add
              </Button>
            </div>
          </form>
          <ul className="m-0 flex list-none flex-col gap-1.5 p-2">
            {routingRules.length === 0 ? (
              <li className="px-0 py-2 text-[13px] text-muted-foreground">No session routing rules.</li>
            ) : (
              routingRules.map((rule) => (
                <li
                  key={`${rule.table}-${rule.id}`}
                  className="flex items-center justify-between gap-2 rounded-lg border border-border p-2 data-[enabled=false]:opacity-60"
                  data-enabled={rule.enabled ? "true" : "false"}
                >
                  <div className="min-w-0">
                    <strong className="block max-w-[150px] overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[11px] font-semibold text-foreground">
                      {rule.matcher || `Rule ${rule.id}`}
                    </strong>
                    <span className="block max-w-[150px] overflow-hidden text-ellipsis whitespace-nowrap text-xs text-muted-foreground">
                      {rule.receivers_text || (rule.receivers || []).join(", ")}
                    </span>
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

// Shared shadcn token class strings for the conversation surface.
const routingFieldClass = "h-[34px] min-w-0 rounded-md border border-border bg-card px-2.5 text-[13px] text-foreground"

function segmentClass(active: boolean) {
  const base = "inline-flex min-h-[30px] items-center gap-1.5 rounded-md px-2.5 text-[13px] font-semibold"
  return active ? `${base} bg-card text-foreground shadow-sm` : `${base} text-muted-foreground`
}

// Message bubble styling — the viewer's own turns are the one bold element
// (filled accent, right-aligned); agent turns get a tinted, accent-edged,
// mono-body card; other humans get a quiet neutral card.
function bubbleClass(mine: boolean, kind: string) {
  const base = "flex max-w-[78%] flex-col gap-1.5 rounded-[10px] border px-3 py-2.5 shadow-sm"
  if (mine) return `${base} self-end border-primary bg-primary text-primary-foreground`
  if (kind === "agent")
    return `${base} self-start border-emerald-300 border-l-[3px] border-l-emerald-600 bg-emerald-50 dark:border-emerald-900 dark:border-l-emerald-500 dark:bg-emerald-950/40`
  return `${base} self-start border-border bg-card`
}

function bubbleKindClass(mine: boolean, kind: string) {
  const base = "font-mono text-[10px] font-semibold uppercase tracking-wider"
  if (mine) return `${base} text-primary-foreground`
  if (kind === "agent") return `${base} text-emerald-700 dark:text-emerald-300`
  return `${base} text-muted-foreground`
}

function bubbleTextClass(mine: boolean, kind: string) {
  const base = "m-0 whitespace-pre-wrap break-words leading-relaxed"
  if (mine) return `${base} text-sm text-primary-foreground`
  if (kind === "agent") return `${base} font-mono text-[13px] text-foreground`
  return `${base} text-sm text-foreground`
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

// TEMPORARY internal preview of a hello session's rendered page. Embeds the
// public `/socialware/external` surface (the working renderer) in an iframe,
// rather than the native @json-render island. The proper home for this is world
// surfacing the registered `HelloPageView` (Phase 3 — world becomes a hello app);
// until then this is a clearly-labelled stopgap so an internal reader can see the page
// without leaving the console. Hello sessions are `public_view`, so the customer
// URL renders with no token/login.
function HelloPagePreview({
  sessionUri,
  onPublishTemplate,
}: {
  sessionUri: string
  onPublishTemplate: (sessionUri: string, name: string) => void
}) {
  const src = `/socialware/external?session_uri=${encodeURIComponent(sessionUri)}`
  const [publishOpen, setPublishOpen] = React.useState(false)
  const [name, setName] = React.useState("")
  const [published, setPublished] = React.useState(false)

  // Publish the current session as a template. The dispatch is fire-and-forget
  // (world:dispatch), so confirm optimistically — the new template appears in the
  // New-session dropdown once the server finishes.
  const doPublish = () => {
    const trimmed = name.trim()
    if (!trimmed) return
    onPublishTemplate(sessionUri, trimmed)
    setPublishOpen(false)
    setName("")
    setPublished(true)
    window.setTimeout(() => setPublished(false), 3000)
  }

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      {/* operator-only overlay controls — never rendered on the public share page */}
      <div className="absolute right-2.5 top-2.5 z-10 flex flex-col items-end gap-1.5">
        <a
          href={src}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex h-7 w-7 items-center justify-center rounded-md border border-border bg-card/90 text-foreground shadow-sm backdrop-blur transition hover:bg-muted"
          title="在新标签页打开公开页面 / Open public page in a new tab"
          aria-label="Open public page in a new tab"
        >
          <ExternalLink aria-hidden="true" className="h-4 w-4" />
        </a>
        <button
          type="button"
          onClick={() => setPublishOpen(true)}
          className="inline-flex h-7 w-7 items-center justify-center rounded-md border border-border bg-card/90 text-foreground shadow-sm backdrop-blur transition hover:bg-muted"
          title="发布为模板 / Publish as template"
          aria-label="Publish as template"
        >
          <Upload aria-hidden="true" className="h-4 w-4" />
        </button>
      </div>

      {/* antd `message.success`-style toast: page-wide, horizontally centered near
          the top, white pill + green check + shadow, slides down. `fixed` so it
          centers on the whole viewport (not tucked beside the publish button). */}
      {published && (
        <div className="pointer-events-none fixed inset-x-0 top-6 z-[100] flex justify-center">
          <div className="ez-msg-in pointer-events-auto flex items-center gap-2 rounded-lg bg-card px-4 py-2.5 text-sm font-medium text-foreground shadow-lg ring-1 ring-border">
            <CheckCircle2 aria-hidden="true" className="h-[18px] w-[18px] text-emerald-500" />
            已发布为模板
          </div>
        </div>
      )}

      <iframe title="Rendered page" src={src} className="min-h-0 flex-1 border-0 bg-white" />

      <Modal
        open={publishOpen}
        title="发布为模板 / Publish as template"
        footer={
          <>
            <Button variant="ghost" onClick={() => setPublishOpen(false)}>
              取消
            </Button>
            <Button onClick={doPublish} disabled={!name.trim()}>
              发布
            </Button>
          </>
        }
      >
        <label className="block text-sm">
          <span className="mb-1.5 block text-muted-foreground">发布物名称 · Template name</span>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") doPublish()
            }}
            placeholder="例如 官网模板 v1"
            className="w-full rounded-[var(--radius)] border border-border bg-background px-3 py-2 text-sm outline-none focus:border-primary"
          />
        </label>
        <p className="mt-2 text-xs text-muted-foreground">
          发布后可在新建 session 的 Template 下拉里选到它 — 会带上当前页面与 agent,不含历史对话。
        </p>
      </Modal>
    </div>
  )
}
