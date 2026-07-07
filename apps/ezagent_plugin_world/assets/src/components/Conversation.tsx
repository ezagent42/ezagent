import React from "react"
import {Bug, Cable, CheckCircle2, ChevronUp, Copy, ExternalLink, LayoutGrid, Link2, Maximize2, MessageSquare, MoreHorizontal, Paperclip, PanelTop, Plus, RotateCcw, Route, Send, Sparkles, TerminalSquare, Upload, UserMinus, UserPlus, Users, X} from "lucide-react"

import {Button, Input, Modal, Select} from "./ui/primitives"
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

const ICONS: Record<string, React.ComponentType<{className?: string; "aria-hidden"?: boolean}>> = {
  "message-square": MessageSquare,
  terminal: TerminalSquare,
  route: Route,
  link: Link2,
  "panel-top": PanelTop,
  sparkles: Sparkles,
}

const iconFor = (name: string) => ICONS[name] ?? LayoutGrid

const orderViews = (vs: ViewTab[]) => {
  const rank = (id: string) => (id === "conversation" ? 0 : id === "pty" ? 1 : 2)
  return [...vs].sort((a, b) => rank(a.id) - rank(b.id) || a.id.localeCompare(b.id))
}

type SessionRow = {
  uri: string
  name?: string | null
}

type MemberRow = {
  uri: string
  display_name?: string | null
  role_name?: string | null
  online?: boolean
  kind?: string | null
}

type InviteCandidateRow = {
  uri: string
  display_name?: string | null
  kind?: string | null
  flavor?: string | null
}

type ViewTab = {
  id: string
  label: string
  icon: string
  mode: string
}

const ROUTING_MAGIC_RECEIVERS: InviteCandidateRow[] = [
  {uri: "$session_users,$mentions", display_name: "成员与被提及实体", kind: "preset"},
  {uri: "$session_users", display_name: "人类成员", kind: "group"},
  {uri: "$mentions", display_name: "被提及实体", kind: "dynamic"},
  {uri: "$session_members", display_name: "全部会话成员", kind: "group"},
]

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
  create_error?: string | null
  is_hello?: boolean | null
  messages?: MessageRow[]
  oldest_cursor?: string | null
  pty_alive?: boolean
  pty_initial_buffer?: string
  pty_phase?: string
  routing_rules?: RoutingRule[]
  sessions?: SessionRow[]
  templates?: string[]
  members?: MemberRow[]
  invite_candidates?: InviteCandidateRow[]
  routing_entity_candidates?: InviteCandidateRow[]
  views?: ViewTab[]
}

type Props = {
  state: ConversationState
  onAddRoutingRule: (sessionUri: string, rule: Record<string, string>) => void
  onCreate?: (shortName: string, templateName: string) => void
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
  onRemoveParticipant: (sessionUri: string, participant: string) => void
  onPtyInput: (bytes: string) => void
  onPtyResize: (size: {cols: number; rows: number}) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
  // Publish this (hello) session as a reusable SessionTemplate carrying the
  // current page + agent (not the chat history). Operator-only; the button lives
  // in the page-preview overlay, so it never shows on the public share page.
  onPublishTemplate: (sessionUri: string, name: string) => void
}

// The conversation island stays mounted across rail session switches. Server
// `world:state` payloads reset the local transcript for the newly selected
// session; inbound `chat:message` appends and `chat:older` prepends history
// within that active session.
export function Conversation({
  state,
  onAddRoutingRule,
  onCreate,
  onForkConfig,
  onOpenPty,
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
  const templates = state.templates && state.templates.length > 0 ? state.templates : ["default"]
  const routingRules = state.routing_rules || []
  const fallbackViews: ViewTab[] = [{id: "conversation", label: "对话", icon: "message-square", mode: "chat"}]
  const sourceViews = state.views && state.views.length > 0 ? state.views : fallbackViews
  const visibleViews = sourceViews.filter((v) => v.id !== "pty" && v.mode !== "pty")
  const views = visibleViews.length > 0 ? visibleViews : fallbackViews
  const activeId = views.find((v) => v.id === state.active_view)?.id ?? views[0]?.id ?? "conversation"
  const activeMode = views.find((v) => v.id === activeId)?.mode ?? "chat"
  const viewLabel = (view: ViewTab) => (view.id === "conversation" ? "对话" : view.label)
  // TEMPORARY (hello internal view): only hello sessions get a Page tab. The
  // proper home for this is world surfacing registered SessionViews (Phase 3);
  // for now it embeds the external surface. See HelloPagePreview below.
  // Server-detected (has a `:surface` slice) so a session from a PUBLISHED hello
  // template — whose URI carries the template name, not `/hello/` — still gets the
  // Page pane. Falls back to the URI check.
  const isHelloSession = state.is_hello === true || sessionUri.includes("/hello/")

  const [members, setMembers] = React.useState<MemberRow[]>(state.members || [])
  const [inviteCandidates, setInviteCandidates] = React.useState<InviteCandidateRow[]>(state.invite_candidates || [])
  const [routingEntityCandidates, setRoutingEntityCandidates] = React.useState<InviteCandidateRow[]>(state.routing_entity_candidates || [])
  const [messages, setMessages] = React.useState<MessageRow[]>(state.messages || [])
  const [oldestCursor, setOldestCursor] = React.useState<string | null>(state.oldest_cursor || null)
  const [text, setText] = React.useState("")
  const [mentionQuery, setMentionQuery] = React.useState<string | null>(null)
  const [pending, setPending] = React.useState<Pending[]>([])
  const [uploadError, setUploadError] = React.useState<string | null>(null)
  const [uploading, setUploading] = React.useState(false)
  const [creating, setCreating] = React.useState(false)
  const [newSessionName, setNewSessionName] = React.useState("")
  const [newSessionTemplate, setNewSessionTemplate] = React.useState(templates[0])
  const [inviteOpen, setInviteOpen] = React.useState(false)
  const [inviteValue, setInviteValue] = React.useState("")
  const [debugOpen, setDebugOpen] = React.useState(false)
  const [membersOpen, setMembersOpen] = React.useState(false)
  const [toolsOpen, setToolsOpen] = React.useState(false)
  const [publishOpen, setPublishOpen] = React.useState(false)
  const [publishName, setPublishName] = React.useState("")
  const [published, setPublished] = React.useState(false)
  const [ruleMatcherType, setRuleMatcherType] = React.useState("always")
  const [ruleMatcherArg, setRuleMatcherArg] = React.useState("")
  const [ruleReceivers, setRuleReceivers] = React.useState("")
  const matcherUsesEntity = ruleMatcherType === "mention" || ruleMatcherType === "from"
  const matcherUsesText = ruleMatcherType === "text_contains"
  const routingReceiverCandidates = React.useMemo(
    () => [...ROUTING_MAGIC_RECEIVERS, ...routingEntityCandidates],
    [routingEntityCandidates],
  )
  const canSubmitRule = Boolean(ruleReceivers.trim()) && (!matcherUsesEntity || Boolean(ruleMatcherArg.trim())) && (!matcherUsesText || Boolean(ruleMatcherArg.trim()))
  const scrollRef = React.useRef<HTMLDivElement | null>(null)
  const inputRef = React.useRef<HTMLTextAreaElement | null>(null)
  const fileRef = React.useRef<HTMLInputElement | null>(null)
  const markedRef = React.useRef<Set<string>>(new Set())
  const currentSession = sessions.find((session) => session.uri === sessionUri) || null
  const sessionTitle = currentSession ? sessionLabel(currentSession) : sessionUri ? humanizeSessionName(uriSegment(sessionUri)) : "会话"
  const sessionMeta = [countLabel(members.length, "成员"), countLabel(messages.length, "轮次")].join(" · ")

  React.useEffect(() => {
    setMembers(state.members || [])
    setInviteCandidates(state.invite_candidates || [])
    setRoutingEntityCandidates(state.routing_entity_candidates || [])
    setMessages(state.messages || [])
    setOldestCursor(state.oldest_cursor || null)
    setText("")
    setMentionQuery(null)
    setPending([])
    setUploadError(null)
    setCreating(false)
    setNewSessionName("")
    setInviteOpen(false)
    setInviteValue("")
    setMembersOpen(false)
    setPublishOpen(false)
    setPublishName("")
    setPublished(false)
    markedRef.current = new Set()
  }, [state.session_uri])

  React.useEffect(() => {
    if (!templates.includes(newSessionTemplate)) setNewSessionTemplate(templates[0])
  }, [newSessionTemplate, templates])

  // @mention autocomplete: the open token is the @word immediately before the
  // caret. Inserting the member's URI path segment keeps it a single bare
  // token the server-side parser resolves (display names may contain spaces).
  const mentionMatches = React.useMemo(() => {
    if (mentionQuery === null) return []
    const q = mentionQuery.toLowerCase()
    return members
      .filter((m) => {
        const seg = uriSegment(m.uri).toLowerCase()
        const label = memberLabel(m).toLowerCase()
        const role = (m.role_name || "").toLowerCase()
        return q === "" || seg.includes(q) || label.includes(q) || role.includes(q)
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
      const next = payload as {members?: MemberRow[]; invite_candidates?: InviteCandidateRow[]; routing_entity_candidates?: InviteCandidateRow[]}
      if (next.members) setMembers(next.members)
      if (next.invite_candidates) setInviteCandidates(next.invite_candidates)
      if (next.routing_entity_candidates) setRoutingEntityCandidates(next.routing_entity_candidates)
    })

    return undefined
  }, [onServerEvent])

  React.useEffect(() => {
    setInviteCandidates(state.invite_candidates || [])
  }, [state.invite_candidates])

  React.useEffect(() => {
    setRoutingEntityCandidates(state.routing_entity_candidates || [])
  }, [state.routing_entity_candidates])

  React.useEffect(() => {
    if (inviteValue && !inviteCandidates.some((candidate) => candidate.uri === inviteValue)) {
      setInviteValue("")
    }
  }, [inviteCandidates, inviteValue])

  React.useEffect(() => {
    if (ruleReceivers && !routingReceiverCandidates.some((candidate) => candidate.uri === ruleReceivers)) {
      setRuleReceivers("")
    }
  }, [routingReceiverCandidates, ruleReceivers])

  React.useEffect(() => {
    if (matcherUsesEntity && ruleMatcherArg && !routingEntityCandidates.some((candidate) => candidate.uri === ruleMatcherArg)) {
      setRuleMatcherArg("")
    }
  }, [matcherUsesEntity, routingEntityCandidates, ruleMatcherArg])

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

  const submitCreate = (event: React.FormEvent) => {
    event.preventDefault()
    const trimmed = newSessionName.trim()
    const template = newSessionTemplate.trim() || "default"
    if (!trimmed) return
    onCreate?.(trimmed, template)
    setNewSessionName("")
    setNewSessionTemplate(templates[0])
    setCreating(false)
  }

  const doPublish = () => {
    const trimmed = publishName.trim()
    if (!trimmed || !sessionUri) return
    onPublishTemplate(sessionUri, trimmed)
    setPublishOpen(false)
    setPublishName("")
    setPublished(true)
    window.setTimeout(() => setPublished(false), 3000)
  }

  const toggleMembers = () => {
    if (membersOpen) setInviteOpen(false)
    setMembersOpen(!membersOpen)
  }

  const loadOlder = () => {
    if (oldestCursor && sessionUri) onLoadOlder(sessionUri, oldestCursor)
  }

  const submitRule = (event: React.FormEvent) => {
    event.preventDefault()
    if (!sessionUri) return
    const receivers = ruleReceivers.trim()
    if (!receivers) return
    const matcherArg = matcherUsesEntity || matcherUsesText ? ruleMatcherArg.trim() : ""
    if ((matcherUsesEntity || matcherUsesText) && !matcherArg) return
    onAddRoutingRule(sessionUri, {
      matcher_type: ruleMatcherType,
      matcher_arg: matcherArg,
      receivers,
    })
    setRuleMatcherType("always")
    setRuleMatcherArg("")
    setRuleReceivers("")
  }

  return (
    <>
    <div
      className={[
        "grid h-full min-h-0 overflow-hidden border border-border bg-card shadow-[var(--shadow-card)]",
        membersOpen ? "lg:grid-cols-[276px_minmax(430px,1fr)_260px]" : "lg:grid-cols-[276px_minmax(430px,1fr)]",
      ].join(" ")}
      data-world-component="conversation"
      data-world-user-surface="conversation"
      data-world-chat-layout="im"
    >
      <aside
        className="hidden min-h-0 flex-col overflow-hidden border-r border-border bg-[#fafafa] text-card-foreground lg:flex"
        aria-label="会话"
        data-world-session-rail
      >
        <div className="flex min-h-[58px] items-center justify-between gap-2.5 border-b border-border px-3 py-2.5">
          <div>
            <h2 className="text-[13px] font-bold text-foreground">会话</h2>
            <p className="mt-0.5 text-[11px] text-muted-foreground">当前工作区</p>
          </div>
          <Button
            type="button"
            size="sm"
            variant="secondary"
            aria-label={creating ? "关闭新建会话表单" : "新建会话"}
            onClick={() => setCreating((open) => !open)}
          >
            {creating ? <X aria-hidden="true" /> : <Plus aria-hidden="true" />}
          </Button>
        </div>
        {state.create_error && (
          <p
            className="mx-2.5 mt-2.5 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
            role="alert"
            data-world-session-create-error
          >
            {state.create_error}
          </p>
        )}
        {creating && (
          <form
            className="m-2.5 grid gap-2.5 rounded-lg border border-border bg-muted/30 p-3"
            id="world-session-create-form"
            onSubmit={submitCreate}
          >
            <label className="grid gap-1 text-[11px] font-medium text-muted-foreground" htmlFor="world-conversation-session-name">
              名称
              <Input
                id="world-conversation-session-name"
                value={newSessionName}
                onChange={(event) => setNewSessionName(event.target.value)}
                placeholder="support-triage"
                autoFocus
              />
            </label>
            <label className="grid gap-1 text-[11px] font-medium text-muted-foreground" htmlFor="world-conversation-session-template">
              模板
              <Select
                id="world-conversation-session-template"
                value={newSessionTemplate}
                onChange={(event) => setNewSessionTemplate(event.target.value)}
              >
                {templates.map((template) => (
                  <option key={template} value={template}>
                    {template}
                  </option>
                ))}
              </Select>
            </label>
            <Button type="submit" size="sm" disabled={!newSessionName.trim()}>
              <Plus aria-hidden="true" />
              创建
            </Button>
          </form>
        )}
        <div className="min-h-0 flex-1 overflow-y-auto p-2.5">
          <div className="mb-2 min-h-[34px] rounded-[10px] border border-border bg-muted px-2.5 py-2 text-[12px] text-muted-foreground">
            筛选会话、模板、状态
          </div>
          {sessions.length === 0 ? (
            <p className="px-2 py-3 text-[13px] leading-relaxed text-muted-foreground">当前工作区暂无会话。</p>
          ) : (
            <ul className="m-0 flex list-none flex-col gap-2 p-0">
              {sessions.map((session) => {
                const active = session.uri === sessionUri
                const label = sessionLabel(session)

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
                        <span className="mt-0.5 block truncate text-[11px] opacity-75">
                          会话
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
            <h2 className="text-[13px] font-bold text-foreground">{sessionTitle}</h2>
            <p className="mt-0.5 max-w-[48ch] truncate text-[11px] text-muted-foreground">{sessionUri ? sessionMeta : "未选择会话"}</p>
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
                aria-label="切换会话"
              >
                {sessions.map((session) => (
                  <option key={session.uri} value={session.uri}>
                    {sessionLabel(session)}
                  </option>
                ))}
              </select>
            )}
            <div className="inline-flex items-center rounded-[10px] border border-border bg-muted p-[3px]" aria-label="会话视图">
              {orderViews(views).map((v) => {
                const Icon = iconFor(v.icon)
                const label = viewLabel(v)
                return (
                  <button
                    key={v.id}
                    type="button"
                    className={segmentClass(activeId === v.id)}
                    onClick={() => sessionUri && onSwitchView(sessionUri, v.id)}
                    aria-label={"显示" + label}
                  >
                    <Icon aria-hidden={true} className="h-[15px] w-[15px]" />
                    {label}
                  </button>
                )
              })}
            </div>
            <div className="relative" data-world-session-tools>
              <Button type="button" size="sm" variant="secondary" onClick={() => setToolsOpen((open) => !open)} aria-label="打开会话工具">
                <MoreHorizontal aria-hidden="true" />
              </Button>
              {toolsOpen && (
                <div className="absolute right-0 top-[calc(100%+6px)] z-30 grid w-56 gap-1 rounded-lg border border-border bg-card p-1.5 text-sm shadow-xl">

                  <button
                    type="button"
                    className="flex items-center gap-2 rounded-md px-2.5 py-2 text-left text-foreground hover:bg-muted"
                    onClick={() => {
                      if (sessionUri) onRestartOrchestrator(sessionUri)
                      setToolsOpen(false)
                    }}
                  >
                    <RotateCcw aria-hidden="true" className="h-4 w-4 text-muted-foreground" />
                    重启 agent runner
                  </button>
                  {sessionUri && (
                    <a
                      data-world-external-mirror-link
                      href={`/admin/sessions/${encodeURIComponent(sessionUri)}/external_mirror`}
                      className="flex items-center gap-2 rounded-md px-2.5 py-2 text-left text-foreground hover:bg-muted"
                      onClick={() => setToolsOpen(false)}
                    >
                      <Cable aria-hidden="true" className="h-4 w-4 text-muted-foreground" />
                      外部镜像
                    </a>
                  )}
                  <button
                    type="button"
                    className="flex items-center gap-2 rounded-md px-2.5 py-2 text-left text-foreground hover:bg-muted"
                    onClick={() => {
                      setDebugOpen((open) => !open)
                      setToolsOpen(false)
                    }}
                  >
                    <Bug aria-hidden="true" className="h-4 w-4 text-muted-foreground" />
                    调试信息
                  </button>
                </div>
              )}
            </div>
            {isHelloSession && sessionUri && (
              <Button type="button" size="sm" onClick={() => setPublishOpen(true)} aria-label="发布为模板" data-world-publish-template-button>
                <Upload aria-hidden="true" />
                发布
              </Button>
            )}
            <Button type="button" size="sm" variant="secondary" onClick={() => sessionUri && onForkConfig(sessionUri)} aria-label="复制配置，建新会话" title="复制配置，建新会话">
              <Copy aria-hidden="true" />
            </Button>
            <Button type="button" size="sm" variant={membersOpen ? "default" : "secondary"} onClick={toggleMembers} aria-expanded={membersOpen} aria-label={membersOpen ? "收起成员面板" : "展开成员面板"} data-world-members-toggle>
              <Users aria-hidden="true" />
              成员 {members.length}
            </Button>
          </div>
        </div>

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
                    加载更早消息
                  </Button>
                </div>
              )}

              {messages.length === 0 ? (
                <p className="m-auto max-w-[38ch] text-center text-[13.5px] leading-relaxed text-muted-foreground">
                  这个会话还没有消息。发送第一条消息开始对话。
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
                          {message.sender_display || uriSegment(message.sender)}
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
                  <ul className="absolute bottom-[calc(100%+6px)] left-0 right-0 z-20 m-0 max-h-[220px] list-none overflow-y-auto rounded-lg border border-border bg-card p-1 shadow-xl" role="listbox" aria-label="提及成员">
                    {mentionMatches.map((member) => {
                      const label = memberLabel(member)
                      const token = uriSegment(member.uri)

                      return (
                        <li key={member.uri}>
                          <button
                            type="button"
                            className="flex w-full min-w-0 items-baseline gap-2 rounded-md px-2.5 py-1.5 text-left text-foreground hover:bg-muted"
                            onMouseDown={(event) => {
                              // mousedown (not click) so the textarea doesn't blur first
                              event.preventDefault()
                              insertMention(member)
                            }}
                          >
                            <span className="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[12.5px] font-semibold text-foreground">{label}</span>
                            {label !== token && (
                              <span className="shrink-0 font-mono text-[11.5px] text-muted-foreground">@{token}</span>
                            )}
                          </button>
                        </li>
                      )
                    })}
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
                  placeholder="输入消息… 使用 @ 提及成员"
                  rows={2}
                  aria-label="消息"
                />
                {pending.length > 0 && (
                  <ul className="m-0 mt-2 flex list-none flex-wrap gap-1.5 p-0" aria-label="待发送附件">
                    {pending.map((p) => (
                      <li key={p.id} className="inline-flex items-center gap-1.5 rounded-full bg-foreground/[0.06] py-0.5 pl-2 pr-1.5 text-xs text-foreground">
                        <Paperclip aria-hidden="true" className="h-3 w-3" />
                        <span className="max-w-[18ch] overflow-hidden text-ellipsis whitespace-nowrap">{p.name}</span>
                        <button
                          type="button"
                          className="inline-flex rounded-full p-0.5 text-muted-foreground hover:bg-foreground/10 hover:text-foreground"
                          aria-label={`移除附件 ${p.name}`}
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
                  aria-label="添加附件"
                >
                  <Paperclip aria-hidden="true" />
                </Button>
                <Button type="submit" size="sm" disabled={uploading || (!text.trim() && pending.length === 0)}>
                  <Send aria-hidden="true" />
                  发送
                </Button>
              </div>
            </form>
            </div>
            {isHelloSession && (
              <div className="hidden min-w-0 flex-1 border-l border-border lg:flex lg:flex-col">
                <HelloPagePreview sessionUri={sessionUri} />
              </div>
            )}
          </div>

        {debugOpen && (
          <pre className="m-0 overflow-auto border-t border-border bg-[#111827] px-4 py-3 font-mono text-xs text-[#d1d5db]">
            {JSON.stringify({sessionUri, activeId, activeMode, members: members.length, messages: messages.length}, null, 2)}
          </pre>
        )}
      </section>

      {membersOpen && (
      <aside className="flex min-h-0 flex-col overflow-hidden border-l border-border bg-[#fafafa] text-card-foreground" aria-label="成员">
        <div className="flex min-h-[58px] items-start justify-between gap-2.5 border-b border-border px-4 py-3">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">成员</p>
            <h2 className="text-[17px] font-semibold text-foreground">{members.length}</h2>
          </div>
          <Button
            size="sm"
            variant="secondary"
            disabled={inviteCandidates.length === 0}
            title={inviteCandidates.length === 0 ? "暂无可邀请成员" : "邀请成员"}
            onClick={() => {
              setInviteValue((current) => current || inviteCandidates[0]?.uri || "")
              setInviteOpen(true)
            }}
            aria-label="邀请成员"
          >
            <UserPlus aria-hidden="true" />
            邀请
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
            <label className="text-[11px] text-muted-foreground" htmlFor="world-invite-select">
              邀请成员
            </label>
            <select
              id="world-invite-select"
              data-world-invite-select
              className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-xs text-foreground"
              value={inviteValue}
              onChange={(event) => setInviteValue(event.target.value)}
              autoFocus
              disabled={inviteCandidates.length === 0}
            >
              <option value="" disabled>
                {inviteCandidates.length === 0 ? "暂无可邀请成员" : "选择成员"}
              </option>
              {inviteCandidates.map((candidate) => {
                const label = inviteCandidateLabel(candidate)
                return (
                  <option key={candidate.uri} value={candidate.uri}>
                    {label} ({kindBadgeLabel(candidate.kind)})
                  </option>
                )
              })}
            </select>
            <div className="flex gap-2">
              <Button type="submit" size="sm" disabled={!inviteValue.trim() || inviteCandidates.length === 0}>
                邀请
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
                取消
              </Button>
            </div>
          </form>
        )}
        <ul className="m-0 flex list-none flex-col gap-0.5 overflow-y-auto p-2">
          {members.length === 0 ? (
            <li className="px-2 py-2.5 text-[13px] text-muted-foreground">暂无成员。</li>
          ) : (
            members.map((member) => {
              const label = memberLabel(member)
              return (
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
                  <span className="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[13px] text-foreground">
                    {label}
                  </span>
                  <span className="rounded-full border border-border px-1.5 py-0.5 text-[9.5px] font-semibold uppercase tracking-wide text-muted-foreground">{kindBadgeLabel(member.kind)}</span>

                  {member.uri !== callerUri && (
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      onClick={() => sessionUri && onRemoveParticipant(sessionUri, member.uri)}
                      aria-label={`移除 ${label}`}
                      title="从会话移除"
                    >
                      <UserMinus aria-hidden="true" />
                    </Button>
                  )}
                </li>
              )
            })
          )}
        </ul>

        <details className="border-t border-border px-2 py-3" data-world-routing-drawer>
          <summary className="flex cursor-pointer list-none items-center justify-between gap-2 rounded-md px-2 py-1.5 text-sm font-medium text-muted-foreground hover:bg-muted hover:text-foreground">
            <span className="inline-flex items-center gap-2">
              <Route aria-hidden="true" className="h-[15px] w-[15px]" />
              高级规则
            </span>
            <span className="rounded-full border border-border px-1.5 py-0.5 text-[11px]">{routingRules.length}</span>
          </summary>
          <form className="mt-2 grid grid-cols-[minmax(0,0.9fr)_minmax(0,1fr)] gap-2" id="world-session-routing-form" onSubmit={submitRule}>
            <select
              className={routingFieldClass}
              value={ruleMatcherType}
              onChange={(event) => {
                setRuleMatcherType(event.target.value)
                setRuleMatcherArg("")
              }}
              aria-label="匹配类型"
            >
              <option value="always">总是</option>
              <option value="mention">提及</option>
              <option value="from">来自</option>
              <option value="text_contains">文本包含</option>
            </select>
            {matcherUsesText ? (
              <input
                className={routingFieldClass}
                value={ruleMatcherArg}
                onChange={(event) => setRuleMatcherArg(event.target.value)}
                placeholder="要匹配的文本"
                data-world-routing-matcher-text
                aria-label="匹配文本"
              />
            ) : (
              <select
                className={routingFieldClass}
                value={ruleMatcherArg}
                onChange={(event) => setRuleMatcherArg(event.target.value)}
                data-world-routing-matcher-select
                disabled={ruleMatcherType === "always" || routingEntityCandidates.length === 0}
                aria-label="匹配实体"
              >
                <option value="" disabled>
                  {ruleMatcherType === "always"
                    ? "无需匹配条件"
                    : routingEntityCandidates.length === 0
                      ? "暂无可用实体"
                      : "选择实体"}
                </option>
                {routingEntityCandidates.map((candidate) => (
                  <option key={candidate.uri} value={candidate.uri}>
                    {routingCandidateOptionLabel(candidate)}
                  </option>
                ))}
              </select>
            )}
            <select
              className={`${routingFieldClass} col-span-2`}
              value={ruleReceivers}
              onChange={(event) => setRuleReceivers(event.target.value)}
              data-world-routing-receiver-select
              disabled={routingReceiverCandidates.length === 0}
              aria-label="接收方"
            >
              <option value="" disabled>
                {routingReceiverCandidates.length === 0 ? "暂无可用接收方" : "选择接收方"}
              </option>
              {routingReceiverCandidates.map((candidate) => (
                <option key={candidate.uri} value={candidate.uri}>
                  {routingCandidateOptionLabel(candidate)}
                </option>
              ))}
            </select>
            <div className="col-span-2">
              <Button type="submit" size="sm" disabled={!canSubmitRule}>
                <Plus aria-hidden="true" />
                添加
              </Button>
            </div>
          </form>
          <ul className="m-0 mt-2 flex list-none flex-col gap-1.5 p-0">
            {routingRules.length === 0 ? (
              <li className="px-0 py-2 text-[13px] text-muted-foreground">暂无高级规则。</li>
            ) : (
              routingRules.map((rule) => (
                <li
                  key={`${rule.table}-${rule.id}`}
                  className="flex items-center justify-between gap-2 rounded-lg border border-border p-2 data-[enabled=false]:opacity-60"
                  data-enabled={rule.enabled ? "true" : "false"}
                >
                  <div className="min-w-0">
                    <strong className="block max-w-[150px] overflow-hidden text-ellipsis whitespace-nowrap text-[11px] font-semibold text-foreground">
                      {rule.matcher || `规则 ${rule.id}`}
                    </strong>
                    <span className="block max-w-[150px] overflow-hidden text-ellipsis whitespace-nowrap text-xs text-muted-foreground">
                      {routingReceiversLabel(rule)}
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
                    {rule.enabled ? "停用" : "启用"}
                  </Button>
                </li>
              ))
            )}
          </ul>
        </details>
      </aside>
      )}
    </div>

    {published && (
      <div className="pointer-events-none fixed inset-x-0 top-6 z-[100] flex justify-center">
        <div className="ez-msg-in pointer-events-auto flex items-center gap-2 rounded-lg bg-card px-4 py-2.5 text-sm font-medium text-foreground shadow-lg ring-1 ring-border">
          <CheckCircle2 aria-hidden="true" className="h-[18px] w-[18px] text-emerald-500" />
          已发布为模板
        </div>
      </div>
    )}

    <Modal
      open={publishOpen}
      title="发布为模板"
      footer={
        <>
          <Button variant="ghost" onClick={() => setPublishOpen(false)}>
            取消
          </Button>
          <Button onClick={doPublish} disabled={!publishName.trim()}>
            发布
          </Button>
        </>
      }
    >
      <label className="block text-sm">
        <span className="mb-1.5 block text-muted-foreground">发布名称</span>
        <input
          autoFocus
          value={publishName}
          onChange={(e) => setPublishName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") doPublish()
          }}
          placeholder="homesite-v1"
          className="w-full rounded-[var(--radius)] border border-border bg-background px-3 py-2 text-sm outline-none focus:border-primary"
        />
      </label>
      <p className="mt-2 text-xs text-muted-foreground">
        建议使用英文、数字和连字符。发布后可在新建会话的模板下拉里选择它，会带上当前页面与 agent，不含历史对话。
      </p>
    </Modal>
    </>
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

function sessionLabel(session: SessionRow) {
  if (session.name && session.name.trim()) return humanizeSessionName(session.name)
  return humanizeSessionName(uriSegment(session.uri))
}

function humanizeSessionName(value: string) {
  const trimmed = value.trim()
  if (!trimmed) return "会话"
  const withoutPrefix = trimmed.replace(/^conv[_-]/, "")
  return withoutPrefix
    .replace(/[_]+/g, " ")
    .replace(/\s+/g, " ")
    .replace(/\b([a-z])/g, (match) => match.toUpperCase())
}

function memberLabel(member: MemberRow) {
  if (member.display_name && member.display_name.trim()) return member.display_name
  return uriSegment(member.uri)
}

function inviteCandidateLabel(candidate: InviteCandidateRow) {
  if (candidate.display_name && candidate.display_name.trim()) return candidate.display_name
  return uriSegment(candidate.uri)
}

function routingCandidateOptionLabel(candidate: InviteCandidateRow) {
  const label = inviteCandidateLabel(candidate)
  return candidate.kind ? `${label} (${kindBadgeLabel(candidate.kind)})` : label
}

function kindBadgeLabel(kind?: string | null) {
  if (kind === "agent") return "智能体"
  if (kind === "user") return "用户"
  if (kind === "group") return "分组"
  if (kind === "preset") return "预设"
  if (kind === "dynamic") return "动态"
  if (kind === "member") return "成员"
  return "成员"
}

function countLabel(count: number, label: string) {
  return `${count} ${label}`
}

function routingReceiversLabel(rule: RoutingRule) {
  const receivers = rule.receivers && rule.receivers.length > 0 ? rule.receivers : splitReceiverText(rule.receivers_text)
  return receivers.length > 0 ? receivers.map(uriSegment).join(", ") : "无接收方"
}

function splitReceiverText(value?: string | null) {
  if (!value) return []
  return value
    .split(/[,\s]+/)
    .map((item) => item.trim())
    .filter(Boolean)
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
  if (mine) return "我"
  if (kind === "agent") return "智能体"
  if (kind === "user") return "用户"
  return "成员"
}

// TEMPORARY internal preview of a hello session's rendered page. Embeds the
// public `/socialware/external` surface (the working renderer) in an iframe,
// rather than the native @json-render island. The proper home for this is world
// surfacing the registered `HelloPageView` (Phase 3 — world becomes a hello app);
// until then this is a clearly-labelled stopgap so an internal reader can see the page
// without leaving the console. Hello sessions are `public_view`, so the customer
// URL renders with no token/login.
function HelloPagePreview({sessionUri}: {sessionUri: string}) {
  const src = `/socialware/external?session_uri=${encodeURIComponent(sessionUri)}`

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      {/* operator-only overlay control — never rendered on the public share page */}
      <div className="absolute right-2.5 top-2.5 z-10 flex flex-col items-end gap-1.5">
        <a
          href={src}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex h-7 w-7 items-center justify-center rounded-md border border-border bg-card/90 text-foreground shadow-sm backdrop-blur transition hover:bg-muted"
          title="在新标签页打开公开页面"
          aria-label="在新标签页打开公开页面"
        >
          <ExternalLink aria-hidden="true" className="h-4 w-4" />
        </a>
      </div>

      <iframe title="渲染页面预览" src={src} className="min-h-0 flex-1 border-0 bg-white" />
    </div>
  )
}