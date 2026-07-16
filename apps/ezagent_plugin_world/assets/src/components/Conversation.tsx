import React from "react"
import {Bug, Cable, CheckCircle2, ChevronUp, Copy, ExternalLink, LayoutGrid, Link2, Loader2, MessageSquare, MoreHorizontal, Paperclip, PanelTop, Plus, RotateCcw, Route, Send, Sparkles, SquareKanban, TerminalSquare, Upload, UserMinus, UserPlus, Users, X} from "lucide-react"

import {Button, Input, Modal, Select} from "./ui/primitives"
import {JsonRenderBubble} from "./JsonRenderBubble"
import {Kanban, type KanbanState} from "./Kanban"
import {PtyTerminalSurface} from "./PtyTerminal"

/** G5 structured error card pushed by ErrorRenderer */
type DispatchErrorCard = {
  layer: 1 | 2 | 3
  what: string
  impact: string
  fix_link?: string | null
  fix_owner_name?: string | null
  notify_action?: {action: string; args: Record<string, unknown>} | null
  issue_id?: string | null
}

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
  // G5 source 2 — per-viewer error card attached by `ErrorCards.enrich/3` when
  // an AGENT-sent message body carries a structured error. Rendered in
  // addition to `text` (a card never suppresses persisted message content).
  error_card?: DispatchErrorCard | null
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
  "square-kanban": SquareKanban,
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
  pty_alive?: boolean
  kind?: string | null
}

type HumanRoleSlotRow = {
  role_name?: string | null
  assigned_uri?: string | null
}

type InstalledSocialwareRoleRow = {
  role_name?: string | null
  fill?: string | null
}

type InstalledSocialwareRow = {
  name: string
  title?: string | null
  description?: string | null
  roles?: InstalledSocialwareRoleRow[]
}

type MentionMatch = {
  member: MemberRow
  label: string
  badge?: string
  insertText: string
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
  last_dispatch_status?: string | null
  dispatch_error?: DispatchErrorCard | null
  is_hello?: boolean | null
  messages?: MessageRow[]
  oldest_cursor?: string | null
  pty_alive?: boolean
  pty_initial_buffer?: string
  pty_phase?: string
  routing_rules?: RoutingRule[]
  sessions?: SessionRow[]
  templates?: string[]
  session_create_pending?: boolean
  members?: MemberRow[]
  invite_candidates?: InviteCandidateRow[]
  routing_entity_candidates?: InviteCandidateRow[]
  human_role_slots?: HumanRoleSlotRow[]
  installed_socialwares?: InstalledSocialwareRow[]
  unfilled_agent_role_slots?: { role_name: string; reason: string }[]
  degraded_operates_edges?: {
    request_id: string
    source_role: string
    target_role: string
    behavior: string
    action: string
    target_uri: string
    reason: string
    target_approval?: string
    source_approval?: string
  }[]
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
  onUninstallSocialware: (sessionUri: string, ref: string) => void
  onPtyInput: (bytes: string) => void
  onPtyResize: (size: {cols: number; rows: number}) => void
  onServerEvent?: (event: string, callback: (payload: unknown) => void) => void
  pushEvent?: (event: string, payload: unknown) => void
  // Kanban board actions (kanban.*) dispatched from the in-session board tab.
  // Wired to the same `world:dispatch` path the plugin page uses
  // (`onWorkspacePluginAction`); session-agnostic, so no session_uri is threaded.
  onKanbanAction: (action: string, args: Record<string, unknown>) => void
  // Publish this (hello) session as a reusable SessionTemplate carrying the
  // current page + agent (not the chat history). Operator-only; the button lives
  // in the page-preview overlay, so it never shows on the public share page.
  onPublishTemplate: (sessionUri: string, name: string) => void
}

// The conversation island stays mounted across rail session switches. Server
// `world:state` payloads reset the local transcript for the newly selected
// session; inbound `chat:message` appends and `chat:older` prepends history
// within that active session.
// Shared G5 error-card body: rendered by the top-of-rail sync `dispatch_error`
// block AND inline in a message bubble (async agent-reply errors). Wrappers
// (border/margins/data attrs) stay at the call sites.
function ErrorCardContent({
  card,
  pushEvent,
}: {
  card: DispatchErrorCard
  pushEvent?: (event: string, payload: unknown) => void
}) {
  return (
    <>
      <p className="font-semibold text-destructive">{card.what}</p>
      <p className="mt-1 text-muted-foreground">{card.impact}</p>
      {card.layer === 1 && card.fix_link && (
        <a href={card.fix_link} className="mt-2 inline-block text-primary underline">
          前往修复 →
        </a>
      )}
      {card.layer === 2 && card.fix_owner_name && (
        <div className="mt-2">
          <p className="text-sm">
            请联系 <span className="font-medium">{card.fix_owner_name}</span> 修复此问题
          </p>
          <button
            className="mt-1.5 rounded bg-destructive px-3 py-1 text-xs font-medium text-destructive-foreground hover:bg-destructive/90"
            onClick={() => {
              if (card.notify_action && pushEvent) {
                pushEvent("world:dispatch", card.notify_action)
              }
            }}
            data-world-dispatch-error-notify
          >
            发送提醒给 {card.fix_owner_name}
          </button>
        </div>
      )}
      {card.layer === 3 && (
        <p className="mt-1 text-xs text-muted-foreground">此问题已自动登记，团队会跟进处理</p>
      )}
    </>
  )
}

export function Conversation({
  state,
  onAddRoutingRule,
  onCreate,
  onForkConfig,
  onOpenPty,
  onRemoveParticipant,
  onUninstallSocialware,
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
  pushEvent,
  onKanbanAction,
  onPublishTemplate,
}: Props) {
  const sessionUri = state.session_uri || ""
  const callerUri = state.caller_uri || ""
  const sessions = state.sessions || []
  const templates = state.templates && state.templates.length > 0 ? state.templates : ["default"]
  const routingRules = state.routing_rules || []
  const installedSocialwares = state.installed_socialwares || []
  const unfilledRoleSlots = state.unfilled_agent_role_slots || []
  const degradedOperatesEdges = state.degraded_operates_edges || []
  const fallbackViews: ViewTab[] = [{id: "conversation", label: "对话", icon: "message-square", mode: "chat"}]
  const sourceViews = state.views && state.views.length > 0 ? state.views : fallbackViews
  const views = sourceViews.length > 0 ? sourceViews : fallbackViews
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
  const createPending = state.session_create_pending === true

  const [members, setMembers] = React.useState<MemberRow[]>(state.members || [])
  const [humanRoleSlots, setHumanRoleSlots] = React.useState<HumanRoleSlotRow[]>(state.human_role_slots || [])
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
  const [routingOpen, setRoutingOpen] = React.useState(false)
  const [toolsOpen, setToolsOpen] = React.useState(false)
  const [publishOpen, setPublishOpen] = React.useState(false)
  const [publishName, setPublishName] = React.useState("")
  const [published, setPublished] = React.useState(false)
  // Kanban 分享链接：点分享 → dispatch kanban.share_board → 后端回推 world:state.share_link
  // → 弹 modal（㉙ 两选项：分享到会话 / 复制分享链接）。shareRequestedRef 保证
  // 只有用户点了分享才弹（避免挂载时 state 里已有旧 share_link 就自弹）。
  const [shareLink, setShareLink] = React.useState<string | null>(null)
  // ㉚ 复制真实成败：copied=已复制 / failed=复制失败（回退也没成，提示手动复制）
  const [shareCopyState, setShareCopyState] = React.useState<"copied" | "failed" | null>(null)
  // ㉙ 分享到会话后的轻提示
  const [sharedToSession, setSharedToSession] = React.useState(false)
  const [shareBoardName, setShareBoardName] = React.useState<string | null>(null)
  const shareRequestedRef = React.useRef(false)
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
  const ptyMembers = members.filter((member) => member.kind === "agent" && member.pty_alive === true)
  const activePtyAgentUri = state.agent_uri || state.active_pty_agent_uri || null

  React.useEffect(() => {
    setMembers(state.members || [])
    setHumanRoleSlots(state.human_role_slots || [])
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
    setRoutingOpen(false)
    setPublishOpen(false)
    setPublishName("")
    setPublished(false)
    markedRef.current = new Set()
  }, [state.session_uri])

  React.useEffect(() => {
    if (!templates.includes(newSessionTemplate)) setNewSessionTemplate(templates[0])
  }, [newSessionTemplate, templates])

  React.useEffect(() => {
    if (!createPending && state.last_dispatch_status === "ok") {
      setNewSessionName("")
      setNewSessionTemplate(templates[0])
      setCreating(false)
    }
  }, [createPending, state.last_dispatch_status, templates])

  // @mention autocomplete: the open token is the @word immediately before the
  // caret. Matches consider URI segment, role_name, display_name, and
  // colon-role fallback; insertion prefers parser-safe human-readable tokens.
  const mentionMatches = React.useMemo(() => {
    if (mentionQuery === null) return []
    const q = mentionQuery.toLowerCase()
    return members
      .flatMap((member) => mentionMatch(member, q, members, humanRoleSlots))
      .slice(0, 6)
  }, [mentionQuery, members, humanRoleSlots])

  const onComposerChange = (value: string, caret: number) => {
    setText(value)
    const upto = value.slice(0, caret)
    const m = upto.match(/(?:^|[^\p{L}\p{N}_])@([A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?)?$/u)
    setMentionQuery(m ? m[1] || "" : null)
  }

  const insertMention = (match: MentionMatch) => {
    const el = inputRef.current
    const caret = el ? el.selectionStart : text.length
    const upto = text.slice(0, caret)
    const rest = text.slice(caret)
    const replaced = upto.replace(/@([A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?)?$/u, `@${match.insertText} `)
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
      const next = payload as {
        members?: MemberRow[]
        human_role_slots?: HumanRoleSlotRow[]
        invite_candidates?: InviteCandidateRow[]
        routing_entity_candidates?: InviteCandidateRow[]
      }
      if (next.members) setMembers(next.members)
      if (next.human_role_slots) setHumanRoleSlots(next.human_role_slots)
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
    } catch {
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
    if (!trimmed || createPending) return
    onCreate?.(trimmed, template)
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

  // ㉗④ kanban 节点「附件」产物：复用平台 uploads 通道（与上方 chat 附件同一
  // cap-authed 端点 /world/uploads），拿 {grant, name} 交给 Kanban 面板 dispatch
  // kanban.attach_upload 挂节点。失败回 null（面板就地提示）。
  const uploadForKanban = async (file: File): Promise<{grant: string; name: string} | null> => {
    if (!sessionUri || file.size > MAX_FILE_BYTES) return null
    const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
    const form = new FormData()
    form.append("session", sessionUri)
    form.append("file", file)
    try {
      const res = await fetch("/world/uploads", {
        method: "POST",
        headers: {"x-csrf-token": csrf},
        body: form,
        credentials: "same-origin",
      })
      if (!res.ok) return null
      const data = (await res.json()) as {name?: string; grant?: string}
      return data.grant ? {grant: data.grant, name: data.name || file.name} : null
    } catch {
      return null
    }
  }

  // 分享看板：dispatch kanban.share_board（复用 onKanbanAction=world:dispatch），后端回推
  // share_link；标记 shareRequestedRef 让下方 effect 只在本次用户动作后弹链接。
  const handleShareKanban = (kanbanUri: string) => {
    if (!kanbanUri) return
    shareRequestedRef.current = true
    setShareBoardName(kanbanUri.split("/").filter(Boolean).pop() || null)
    onKanbanAction("kanban.share_board", {kanban_uri: kanbanUri})
  }

  // ㉚ 复制：navigator.clipboard 仅安全上下文（https/localhost）可用，经 http://<IP>
  // 访问时静默失败——回退 textarea 选中 + document.execCommand("copy")，并把真实
  // 成败反馈给用户（不再无条件宣称"已复制"）。
  const copyShareLink = async (link: string) => {
    const ok = await copyTextRobust(link)
    setShareCopyState(ok ? "copied" : "failed")
    if (ok) window.setTimeout(() => setShareCopyState((cur) => (cur === "copied" ? null : cur)), 2000)
  }

  // ㉙ 分享到会话：把带板引用的分享链接作为消息发进当前 session chat（现有
  // session.send 通道）；消息文本带接收链接 → chat 渲染层的链接 unfurl 注册表
  // （㉝，见 unfurl.tsx）把它渲成看板气泡（不显示裸链接）。
  const shareToSession = (link: string) => {
    if (!sessionUri) return
    const label = shareBoardName ? `看板「${shareBoardName}」` : "看板"
    onSend(sessionUri, `【看板分享】${label} ${link}`, [])
    setShareLink(null)
    setSharedToSession(true)
    window.setTimeout(() => setSharedToSession(false), 2000)
  }

  const kanbanShareLink = (state as unknown as KanbanState).share_link
  React.useEffect(() => {
    if (!kanbanShareLink || !shareRequestedRef.current) return
    shareRequestedRef.current = false
    setShareCopyState(null)
    setShareLink(kanbanShareLink)
    void copyShareLink(kanbanShareLink)
  }, [kanbanShareLink])

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
        {state.dispatch_error && (
          <div
            className="mx-2.5 mt-2.5 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm"
            role="alert"
            data-world-dispatch-error
          >
            <ErrorCardContent card={state.dispatch_error} pushEvent={pushEvent} />
          </div>
        )}
        {creating && (
          <form
            className="m-2.5 grid gap-2.5 rounded-lg border border-border bg-muted/30 p-3"
            id="world-session-create-form"
            aria-busy={createPending}
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
            <Button type="submit" size="sm" disabled={createPending || !newSessionName.trim()}>
              {createPending ? <Loader2 className="animate-spin" aria-hidden="true" /> : <Plus aria-hidden="true" />}
              {createPending ? "创建中" : "创建"}
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
                const selected = v.id === "routing" ? membersOpen && routingOpen : activeId === v.id

                if (v.id === "external_mirror") {
                  return (
                    <a
                      key={v.id}
                      href={`/admin/sessions/${encodeURIComponent(sessionUri)}/external_mirror`}
                      className={segmentClass(false)}
                      aria-label={"显示" + label}
                      data-world-bindings-tab
                    >
                      <Icon aria-hidden={true} className="h-[15px] w-[15px]" />
                      {label}
                    </a>
                  )
                }

                return (
                  <button
                    key={v.id}
                    type="button"
                    className={segmentClass(selected)}
                    onClick={() => {
                      if (!sessionUri) return
                      if (v.id === "routing") {
                        setInviteOpen(false)
                        setMembersOpen(true)
                        setRoutingOpen(true)
                        return
                      }
                      if (v.id === "pty" || v.mode === "pty") {
                        const agent = activePtyAgentUri || ptyMembers[0]?.uri
                        if (agent) onOpenPty(sessionUri, agent)
                        else onSwitchView(sessionUri, v.id)
                      } else {
                        onSwitchView(sessionUri, v.id)
                      }
                    }}
                    aria-label={"显示" + label}
                    data-world-routing-tab={v.id === "routing" ? true : undefined}
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
          {activeMode === "kanban" ? (
            // 权限门控的 session tab 里渲染富 Kanban 操作面（复用插件页同一组件）。
            // board 数据来自 world:state 合并的看板字段（后端 session.view.switch 切到
            // kanban_board 时经 KanbanData.session_boards 载入 + 自动选中首块板）；
            // onAction 走现成 world:dispatch（onKanbanAction = onWorkspacePluginAction）。
            <div className="min-w-0 flex-1 overflow-y-auto bg-[#fafafa]" data-world-subcomponent="kanban">
              <Kanban state={state as unknown as KanbanState} onAction={onKanbanAction} onShare={handleShareKanban} onUploadFile={uploadForKanban} />
            </div>
          ) : activeMode === "pty" ? (
            <div className="min-w-0 flex-1 overflow-y-auto bg-[#fafafa] p-4" data-world-subcomponent="pty">
              <PtyTerminalSurface
                state={{...state, agent_uri: activePtyAgentUri}}
                onInput={onPtyInput}
                onResize={onPtyResize}
                onServerEvent={onServerEvent}
              />
            </div>
          ) : (
            <>
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
                      {message.error_card && (
                        // Async agent-reply error (G5 source 2): the per-viewer
                        // card renders IN ADDITION to the text (adversarial
                        // review #2 — a card must never suppress persisted
                        // message content).
                        <div
                          className="mt-1 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm"
                          role="alert"
                          data-world-message-error-card
                        >
                          <ErrorCardContent card={message.error_card} pushEvent={pushEvent} />
                        </div>
                      )}
                      {message.render != null && typeof message.render === "object" && (
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
                  <ul className="absolute bottom-[calc(100%+6px)] left-0 right-0 z-20 m-0 max-h-[220px] list-none overflow-y-auto rounded-lg border border-border bg-card p-1 shadow-xl" role="listbox" aria-label="mention members">
                    {mentionMatches.map((match) => {
                      const token = match.insertText

                      return (
                        <li key={match.member.uri}>
                          <button
                            type="button"
                            className="flex w-full min-w-0 items-baseline gap-2 rounded-md px-2.5 py-1.5 text-left text-foreground hover:bg-muted"
                            onMouseDown={(event) => {
                              // mousedown (not click) so the textarea doesn't blur first
                              event.preventDefault()
                              insertMention(match)
                            }}
                          >
                            <span className="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[12.5px] font-semibold text-foreground">{match.label}</span>
                            {match.badge && (
                              <span className="shrink-0 rounded bg-muted px-1.5 py-0.5 text-[10px] font-semibold uppercase text-muted-foreground">
                                {match.badge}
                              </span>
                            )}
                            {match.label !== token && (
                              <span className="shrink-0 max-w-[48%] overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[11.5px] text-muted-foreground">@{token}</span>
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
            </>
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

                  {member.pty_alive === true && (
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      onClick={() => {
                        if (!sessionUri) return
                        onOpenPty(sessionUri, member.uri)
                      }}
                      data-world-member-pty
                      aria-label={`打开 ${label} 的 PTY`}
                      title="打开 PTY"
                    >
                      <TerminalSquare aria-hidden="true" />
                    </Button>
                  )}

                  {member.uri !== callerUri && (
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      onClick={() => {
                        if (!sessionUri) return
                        if (window.confirm("确定移除 " + label + "？")) {
                          onRemoveParticipant(sessionUri, member.uri)
                        }
                      }}
                      data-world-remove-member
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

        {installedSocialwares.length > 0 && (
          <section className="border-t border-border px-2 py-3" data-world-socialware-uninstall-panel>
            <div className="mb-2 flex items-center justify-between gap-2 px-2">
              <span className="text-sm font-medium text-muted-foreground">已装 Socialware</span>
              <span className="rounded-full border border-border px-1.5 py-0.5 text-[11px] text-muted-foreground">{installedSocialwares.length}</span>
            </div>
            <div className="grid gap-1.5">
              {installedSocialwares.map((socialware) => {
                const title = socialware.title || socialware.name
                const roles = (socialware.roles || []).map((role) => role.role_name).filter(Boolean).join(", ") || "无角色"

                return (
                  <div
                    key={socialware.name}
                    className="rounded-md border border-border bg-card px-2.5 py-2"
                    data-world-socialware-install={socialware.name}
                  >
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <strong className="block overflow-hidden text-ellipsis whitespace-nowrap text-[13px] font-semibold text-foreground">
                          {title}
                        </strong>
                        <span className="block overflow-hidden text-ellipsis whitespace-nowrap text-[11px] text-muted-foreground">
                          {roles}
                        </span>
                      </div>
                      <Button
                        type="button"
                        size="sm"
                        variant="secondary"
                        onClick={() => {
                          if (!sessionUri) return
                          if (window.confirm("确定卸载 " + title + "？")) {
                            onUninstallSocialware(sessionUri, socialware.name)
                          }
                        }}
                        data-world-socialware-uninstall-button
                        aria-label={"卸载 " + title}
                        title="卸载 socialware"
                      >
                        <X aria-hidden="true" />
                        卸载
                      </Button>
                    </div>
                  </div>
                )
              })}
            </div>
          </section>
        )}

        {unfilledRoleSlots.length > 0 && (
          <div className="border-t border-border px-3 py-2.5" data-world-unfilled-role-slots>
            {unfilledRoleSlots.map((slot) => (
              <p key={slot.role_name} className="text-[12px] leading-relaxed text-muted-foreground">
                <strong className="font-medium text-amber-400">{slot.role_name}</strong>
                {" · 未装载"}
                {slot.reason === "missing_credentials" &&
                  "：缺少 Claude 凭证，请在设置中绑定 Claude 登录后再试"}
                {slot.reason !== "missing_credentials" && `（${slot.reason}）`}
              </p>
            ))}
          </div>
        )}

        {degradedOperatesEdges.length > 0 && (
          <div className="border-t border-border px-3 py-2.5" data-world-degraded-operates-edges>
            {degradedOperatesEdges.map((edge) => (
              <p key={edge.request_id || `${edge.source_role}:${edge.target_role}:${edge.behavior}:${edge.action}`} className="text-[12px] leading-relaxed text-muted-foreground">
                <strong className="font-medium text-amber-400">{edge.source_role}</strong>
                {` · 仅参与，暂不能操作 ${edge.target_role}.${edge.action}（${edge.reason}；目标授权 ${edge.target_approval || "pending"}；来源授权 ${edge.source_approval || "pending"}）`}
              </p>
            ))}
          </div>
        )}

        <details
          className="border-t border-border px-2 py-3"
          open={routingOpen}
          onToggle={(event) => setRoutingOpen(event.currentTarget.open)}
          data-world-routing-drawer
        >
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

    {shareCopyState === "copied" && (
      <div className="pointer-events-none fixed inset-x-0 top-6 z-[100] flex justify-center">
        <div className="ez-msg-in pointer-events-auto flex items-center gap-2 rounded-lg bg-card px-4 py-2.5 text-sm font-medium text-foreground shadow-lg ring-1 ring-border">
          <CheckCircle2 aria-hidden="true" className="h-[18px] w-[18px] text-emerald-500" />
          分享链接已复制
        </div>
      </div>
    )}

    {sharedToSession && (
      <div className="pointer-events-none fixed inset-x-0 top-6 z-[100] flex justify-center">
        <div className="ez-msg-in pointer-events-auto flex items-center gap-2 rounded-lg bg-card px-4 py-2.5 text-sm font-medium text-foreground shadow-lg ring-1 ring-border">
          <CheckCircle2 aria-hidden="true" className="h-[18px] w-[18px] text-emerald-500" />
          已分享到会话
        </div>
      </div>
    )}

    {/* ㉙ 分享两选项：①分享到会话（板引用发进当前 chat，渲成看板气泡）②复制分享链接 */}
    <Modal
      open={shareLink !== null}
      title="分享看板"
      footer={
        <>
          <Button variant="ghost" onClick={() => setShareLink(null)}>
            关闭
          </Button>
          <Button variant="secondary" onClick={() => shareLink && copyShareLink(shareLink)} data-world-kanban-share-copy>
            <Copy aria-hidden="true" className="h-4 w-4" />
            复制分享链接
          </Button>
          <Button onClick={() => shareLink && shareToSession(shareLink)} disabled={!sessionUri} data-world-kanban-share-to-session>
            <Send aria-hidden="true" className="h-4 w-4" />
            分享到会话
          </Button>
        </>
      }
    >
      <p className="mb-2 text-sm text-muted-foreground">
        <strong>分享到会话</strong>：把看板以气泡发进当前会话的聊天（成员点击即可加入查看）。
        <br />
        <strong>复制分享链接</strong>：任何拿到链接的人都能<strong>只读</strong>查看这块看板（链接 7 天内有效）。
      </p>
      {shareCopyState === "failed" && (
        <p className="mb-2 text-xs text-destructive" role="alert">
          自动复制失败（当前环境剪贴板不可用）——请点击下方输入框全选后手动复制。
        </p>
      )}
      <div className="flex items-center gap-2">
        <input
          readOnly
          value={shareLink || ""}
          onFocus={(e) => e.target.select()}
          className="w-full rounded-[var(--radius)] border border-border bg-muted px-3 py-2 text-sm text-foreground outline-none"
          data-world-kanban-share-link
        />
      </div>
    </Modal>

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

function mentionMatch(member: MemberRow, q: string, members: MemberRow[], openRoleSlots: HumanRoleSlotRow[]): MentionMatch[] {
  const source = memberMentionSource(member, q) || fallbackMemberMentionSource(member, q, members, openRoleSlots)
  if (!source) return []

  const roleName = member.role_name?.trim()
  const roleDisplay = source === "role" && roleName ? roleMentionDisplay(roleName) : null

  return [
    {
      member,
      label: memberLabel(member),
      badge: roleDisplay?.badge,
      insertText: mentionToken(member, members, openRoleSlots),
    },
  ]
}

function memberMentionSource(member: MemberRow, query: string): "segment" | "role" | "display" | null {
  if (query === "") return "segment"

  const q = query.toLowerCase()
  const seg = uriSegment(member.uri).toLowerCase()
  const role = (member.role_name || "").toLowerCase()
  const name = (member.display_name || "").toLowerCase()

  if (seg.includes(q)) return "segment"
  if (role.includes(q)) return "role"
  if (name.includes(q)) return "display"
  return null
}

function fallbackMemberMentionSource(
  member: MemberRow,
  query: string,
  members: MemberRow[],
  openRoleSlots: HumanRoleSlotRow[],
): "segment" | "role" | "display" | null {
  if (!query.includes(":") || colonRoleNamePresent(members, openRoleSlots)) return null
  return memberMentionSource(member, query.split(":", 1)[0])
}

function roleMentionDisplay(roleName: string) {
  const [source, shortName] = roleName.split(":", 2)
  if (source && shortName) return {label: shortName, badge: source}
  return {label: roleName, badge: "role"}
}

function resolveMemberToken(token: string, members: MemberRow[], openRoleSlots: HumanRoleSlotRow[]) {
  const fullMatch = resolveMemberName(token, members)
  if (fullMatch.length > 0) return fullMatch

  if (token.includes(":") && !colonRoleNamePresent(members, openRoleSlots)) {
    return resolveMemberName(token.split(":", 1)[0], members)
  }

  return []
}

function resolveMemberName(name: string, members: MemberRow[]) {
  const tiers = [
    members.filter((member) => uriSegment(member.uri) === name),
    members.filter((member) => member.role_name === name),
    members.filter((member) => member.display_name === name),
  ]

  for (const tier of tiers) {
    if (tier.length === 0) continue
    const uris = [...new Set(tier.map((member) => member.uri).filter(Boolean))]
    return uris.length === 1 ? uris : []
  }

  return []
}

function colonRoleNamePresent(members: MemberRow[], openRoleSlots: HumanRoleSlotRow[]) {
  return [...members.map((member) => member.role_name), ...openRoleSlots.map((slot) => slot.role_name)].some(
    (roleName) => typeof roleName === "string" && roleName.includes(":"),
  )
}

function uriMentionToken(uri: string) {
  return uri.includes("://") ? uri : uriSegment(uri)
}

function memberLabel(member: MemberRow) {
  if (member.display_name && member.display_name.trim()) return member.display_name
  return uriSegment(member.uri)
}

function mentionToken(member: MemberRow, members: MemberRow[] = [member], openRoleSlots: HumanRoleSlotRow[] = []) {
  const role = member.role_name?.trim()
  if (role && isMentionToken(role) && tokenResolvesToMember(role, member, members, openRoleSlots)) return role

  const label = memberLabel(member).trim()
  if (label && isMentionToken(label) && tokenResolvesToMember(label, member, members, openRoleSlots)) return label

  const segment = uriSegment(member.uri)
  if (segment && tokenResolvesToMember(segment, member, members, openRoleSlots)) return segment

  return uriMentionToken(member.uri)
}

function tokenResolvesToMember(token: string, member: MemberRow, members: MemberRow[], openRoleSlots: HumanRoleSlotRow[]) {
  const resolved = resolveMemberToken(token, members, openRoleSlots)
  return resolved.length === 1 && resolved[0] === member.uri
}

function isMentionToken(value: string) {
  return /^[A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?$/.test(value)
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

// ㉚ 剪贴板写入（真实成败）：先试 navigator.clipboard（仅 https/localhost 安全上下文
// 可用）；失败回退临时 textarea 选中 + document.execCommand("copy")（http://<IP>
// 场景）。两条路都失败返回 false，调用方给出手动复制指引。
async function copyTextRobust(text: string): Promise<boolean> {
  try {
    if (typeof navigator !== "undefined" && navigator.clipboard) {
      await navigator.clipboard.writeText(text)
      return true
    }
  } catch {
    // 继续走回退
  }
  try {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.setAttribute("readonly", "")
    ta.style.position = "fixed"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.focus()
    ta.select()
    const ok = document.execCommand("copy")
    document.body.removeChild(ta)
    return ok
  } catch {
    return false
  }
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
