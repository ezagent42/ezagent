import React from "react"
import {ArrowRight, Bot, Cable, Circle, Loader2, MessageSquare, Plus, UserRound, X} from "lucide-react"

import {Button, Input, Select} from "./ui/primitives"

export type SessionRow = {
  uri: string
  name?: string | null
  workspace_uri?: string | null
}

export type SocialwareRow = {
  name: string
  title?: string | null
  description?: string | null
  config_id?: string | null
  content_hash?: string | null
  scope?: string | null
  workspace_uri?: string | null
  roles?: SocialwareRole[]
}

export type AgentOption = {
  uri: string
  display_name?: string | null
}

export type SocialwareRole = {
  role_name: string
  fill: "agent" | "human"
  recipe?: string | null
  flavor?: string | null
  agent_options?: AgentOption[]
}

export type RoleSlotChoice = {
  role_name: string
  mode: "fresh" | "reuse"
  flavor?: string
  agent_uri?: string
}

export type CreateOptions = {
  role_slots?: RoleSlotChoice[]
  socialware_config_id?: string
  socialware_content_hash?: string
}

export type SessionsState = {
  current_session_uri?: string | null
  sessions?: SessionRow[]
  templates?: string[]
  socialwares?: SocialwareRow[]
  workspace_uri?: string | null
  create_error?: string
  last_dispatch_status?: string | null
  session_create_pending?: boolean
}

type SessionsTableProps = {
  state?: SessionsState
  onJoin?: (sessionUri: string) => void
  onCreate?: (shortName: string, templateName: string, socialwareRef?: string, options?: CreateOptions) => void
}

export function SessionsTable({state, onJoin, onCreate}: SessionsTableProps) {
  const sessions = state?.sessions || []
  const currentSessionUri = state?.current_session_uri
  const templates = state?.templates && state.templates.length > 0 ? state.templates : ["default"]
  const socialwares = state?.socialwares || []
  const [creating, setCreating] = React.useState(false)
  const [filter, setFilter] = React.useState("")
  const [shortName, setShortName] = React.useState("")
  const [templateName, setTemplateName] = React.useState(templates[0])
  const [socialwareRef, setSocialwareRef] = React.useState("")
  const [roleChoices, setRoleChoices] = React.useState<Record<string, RoleSlotChoice>>({})
  const selectedSession =
    sessions.find((session) => session.uri === currentSessionUri) || sessions[0] || null
  const selectedSocialware = socialwares.find((socialware) => socialware.name === socialwareRef) || null
  const createPending = state?.session_create_pending === true

  React.useEffect(() => {
    if (!templates.includes(templateName)) setTemplateName(templates[0])
  }, [templateName, templates])

  React.useEffect(() => {
    if (!createPending && state?.last_dispatch_status === "ok") {
      setShortName("")
      setTemplateName(templates[0])
      setSocialwareRef("")
      setRoleChoices({})
      setCreating(false)
    }
  }, [createPending, state?.last_dispatch_status, templates])

  React.useEffect(() => {
    if (!selectedSocialware) {
      setRoleChoices({})
      return
    }

    setRoleChoices((current) => {
      const next: Record<string, RoleSlotChoice> = {}

      for (const role of selectedSocialware.roles || []) {
        if (role.fill !== "agent") continue
        next[role.role_name] = current[role.role_name] || {
          role_name: role.role_name,
          mode: "fresh",
          flavor: role.flavor || undefined,
        }
      }

      return next
    })
  }, [selectedSocialware])

  const filteredSessions = filterSessions(sessions, filter)

  const submit = (event: React.FormEvent) => {
    event.preventDefault()
    const trimmed = shortName.trim()
    const template = templateName.trim() || "default"
    const installRef = socialwareRef.trim()
    if (!trimmed || createPending) return
    const createOptions = selectedSocialware ? createOptionsFor(selectedSocialware, roleChoices) : undefined
    onCreate?.(trimmed, template, installRef || undefined, createOptions)
  }

  return (
    <section
      className="grid h-full min-h-0 min-w-0 overflow-hidden border-y border-border bg-background text-foreground lg:grid-cols-[276px_minmax(430px,1fr)_260px]"
      aria-labelledby="sessions-title"
      data-world-chat-default
      data-world-component="sessions_table"
    >
      <aside className="flex min-h-0 min-w-0 flex-col border-b border-border bg-card lg:border-b-0 lg:border-r" aria-label="会话" data-world-session-rail>
        <div className="flex items-center justify-between gap-2 border-b border-border px-3 py-3">
          <div className="min-w-0">
            <h2 id="sessions-title" className="truncate text-sm font-semibold text-foreground">
              会话
            </h2>
            <p className="text-xs text-muted-foreground">当前工作区</p>
          </div>
          <Button
            type="button"
            size="icon"
            variant={creating ? "secondary" : "default"}
            onClick={() => setCreating((open) => !open)}
            aria-label={creating ? "关闭新建会话表单" : "新建会话"}
          >
            {creating ? <X aria-hidden="true" /> : <Plus aria-hidden="true" />}
          </Button>
        </div>

        <div className="border-b border-border px-3 py-3">
          <Input
            aria-label="筛选会话"
            value={filter}
            onChange={(event) => setFilter(event.target.value)}
            placeholder="筛选会话、模板、状态"
          />
        </div>

        {state?.create_error && (
          <p
            className="mx-3 mt-3 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
            role="alert"
            data-world-session-create-error
          >
            {state.create_error}
          </p>
        )}

        {creating && (
          <form
            className="m-3 grid gap-3 rounded-md border border-border bg-muted/30 p-3"
            id="world-session-create-form"
            aria-busy={createPending}
            onSubmit={submit}
          >
            <label className="grid gap-1 text-xs font-medium text-muted-foreground" htmlFor="world-session-short-name">
              名称
              <Input
                id="world-session-short-name"
                value={shortName}
                onChange={(event) => setShortName(event.target.value)}
                placeholder="support-triage"
                autoFocus
              />
              <span className="text-[11px] font-normal text-muted-foreground">
                支持字母、数字和 - . _ ~；中文名称暂不支持。
              </span>
            </label>
            <label className="grid gap-1 text-xs font-medium text-muted-foreground" htmlFor="world-session-template">
              模板
              <Select
                id="world-session-template"
                value={templateName}
                onChange={(event) => setTemplateName(event.target.value)}
              >
                {templates.map((template) => (
                  <option key={template} value={template}>
                    {template}
                  </option>
                ))}
              </Select>
            </label>
            {socialwares.length > 0 && (
              <label className="grid gap-1 text-xs font-medium text-muted-foreground" htmlFor="world-session-socialware">
                应用
                <Select
                  id="world-session-socialware"
                  value={socialwareRef}
                  onChange={(event) => setSocialwareRef(event.target.value)}
                >
                  <option value="">不关联</option>
                  {socialwares.map((socialware) => (
                    <option key={socialware.name} value={socialware.name}>
                      {socialware.title || socialware.name}
                    </option>
                  ))}
                </Select>
              </label>
            )}
            {selectedSocialware && (
              <div className="grid gap-2 border-t border-border pt-3" data-world-socialware-install-wizard>
                <div className="min-w-0">
                  <p className="truncate text-xs font-semibold text-foreground">
                    {selectedSocialware.title || selectedSocialware.name}
                  </p>
                  {selectedSocialware.description && (
                    <p className="mt-0.5 line-clamp-2 text-xs text-muted-foreground">{selectedSocialware.description}</p>
                  )}
                </div>
                {(selectedSocialware.roles || []).length === 0 ? (
                  <p className="text-xs text-muted-foreground">No role slots declared.</p>
                ) : (
                  (selectedSocialware.roles || []).map((role) =>
                    role.fill === "agent" ? (
                      <AgentRoleSlot
                        key={role.role_name}
                        role={role}
                        choice={roleChoices[role.role_name]}
                        onChange={(choice) =>
                          setRoleChoices((current) => ({...current, [role.role_name]: choice}))
                        }
                      />
                    ) : (
                      <HumanRoleSlot key={role.role_name} role={role} />
                    ),
                  )
                )}
              </div>
            )}
            <Button type="submit" size="sm" disabled={createPending || !shortName.trim()}>
              {createPending ? <Loader2 className="animate-spin" aria-hidden="true" /> : <Plus aria-hidden="true" />}
              {createPending ? "创建中" : "创建"}
            </Button>
          </form>
        )}

        <div className="min-h-0 flex-1 space-y-1 overflow-y-auto p-2">
          {filteredSessions.length === 0 ? (
            <div className="rounded-md border border-dashed border-border bg-background px-3 py-6 text-center text-sm text-muted-foreground">
              当前工作区暂无会话。
            </div>
          ) : (
            filteredSessions.map((session) => (
              <button
                type="button"
                className="grid w-full grid-cols-[auto_minmax(0,1fr)] gap-2 rounded-md border border-transparent px-2.5 py-2 text-left transition hover:border-border hover:bg-muted/60 data-[active=true]:border-primary/30 data-[active=true]:bg-accent/60"
                data-active={session.uri === selectedSession?.uri ? "true" : "false"}
                key={session.uri}
                onClick={() => onJoin?.(session.uri)}
              >
                <Circle
                  className={
                    session.uri === selectedSession?.uri
                      ? "mt-1 h-2 w-2 fill-[var(--ez-jade)] text-[var(--ez-jade)]"
                      : "mt-1 h-2 w-2 fill-muted-foreground/40 text-muted-foreground/40"
                  }
                  aria-hidden="true"
                />
                <span className="min-w-0">
                  <span className="block truncate text-sm font-medium text-foreground">{displaySessionName(session)}</span>
                  <span className="block truncate text-[11px] text-muted-foreground">{sessionDescription(session)}</span>
                </span>
              </button>
            ))
          )}
        </div>
      </aside>

      <main className="flex min-h-0 min-w-0 flex-col bg-background">
        <header className="flex items-center justify-between gap-3 border-b border-border bg-card px-4 py-3">
          <div className="min-w-0">
            <h3 className="truncate text-sm font-semibold text-foreground">
              {selectedSession ? displaySessionName(selectedSession) : "对话"}
            </h3>
            <p className="truncate text-xs text-muted-foreground">
              {selectedSession ? sessionDescription(selectedSession) : workspaceLabel(state?.workspace_uri) || "未选择会话"}
            </p>
          </div>
          <div className="inline-flex rounded-[10px] border border-border bg-muted p-[3px]" aria-label="会话视图">
            {["对话", "预览"].map((item) => (
              <span
                key={item}
                className={
                  item === "对话"
                    ? "rounded-md bg-background px-3 py-1 text-xs font-medium text-foreground shadow-sm"
                    : "rounded-md px-3 py-1 text-xs font-medium text-muted-foreground"
                }
              >
                {item}
              </span>
            ))}
          </div>
        </header>

        <div className="flex min-h-0 flex-1 items-center justify-center p-6">
          <div className="max-w-md space-y-4 text-center">
            <span className="mx-auto grid h-11 w-11 place-items-center rounded-full border border-border bg-card text-muted-foreground">
              <MessageSquare className="h-5 w-5" aria-hidden="true" />
            </span>
            <div>
              <h4 className="text-base font-semibold text-foreground">
                {selectedSession ? "打开此会话查看对话" : "新建或选择会话"}
              </h4>
              <p className="mt-1 text-sm text-muted-foreground">
                对话会在当前布局中打开，包含消息、输入框、成员和路由工具。
              </p>
            </div>
            {selectedSession && (
              <Button type="button" onClick={() => onJoin?.(selectedSession.uri)}>
                <ArrowRight aria-hidden="true" />
                打开对话
              </Button>
            )}
          </div>
        </div>
      </main>

      <aside className="flex min-h-0 min-w-0 flex-col border-t border-border bg-card lg:border-l lg:border-t-0" aria-label="会话详情">
        <div className="border-b border-border px-4 py-3">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">会话</p>
          <h3 className="truncate text-sm font-semibold text-foreground">
            {selectedSession ? displaySessionName(selectedSession) : "未选择会话"}
          </h3>
        </div>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
          <DetailBlock label="工作区" value={workspaceLabel(selectedSession?.workspace_uri || state?.workspace_uri) || "—"} />
          <DetailBlock label="类型" value={selectedSession ? "会话" : "—"} />

          <div className="space-y-2">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">操作</p>
            {selectedSession ? (
              <div className="grid gap-2">
                <Button type="button" variant="secondary" onClick={() => onJoin?.(selectedSession.uri)}>
                  <ArrowRight aria-hidden="true" />
                  打开
                </Button>
                <a
                  className="inline-flex min-h-9 items-center justify-center gap-2 rounded-full border border-border bg-card px-3 text-sm font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
                  href={`/admin/sessions/${encodeURIComponent(selectedSession.uri)}/external_mirror`}
                  title="绑定飞书群到此会话"
                >
                  <Cable className="h-4 w-4" aria-hidden="true" />
                  外部镜像
                </a>
              </div>
            ) : (
              <p className="text-sm text-muted-foreground">暂无可用操作。</p>
            )}
          </div>
        </div>
      </aside>
    </section>
  )
}

export function filterSessions(sessions: SessionRow[], filter: string): SessionRow[] {
  const q = filter.trim().toLowerCase()
  if (!q) return sessions

  return sessions.filter((session) =>
    [session.uri, session.name, session.workspace_uri]
      .filter(Boolean)
      .some((value) => String(value).toLowerCase().includes(q)),
  )
}

export function displaySessionName(session: SessionRow): string {
  if (session.name && session.name.trim()) return humanizeSessionName(session.name)

  const parts = session.uri.split("/")
  return humanizeSessionName(parts[parts.length - 1] || session.uri)
}

function sessionDescription(session: SessionRow): string {
  const workspace = workspaceLabel(session.workspace_uri)
  return workspace ? `${workspace} 工作区` : "会话"
}

export function workspaceLabel(uri?: string | null): string {
  if (!uri) return ""
  return uri.replace(/^workspace:\/\//, "")
}

export function humanizeSessionName(value: string): string {
  const trimmed = value.trim()
  if (!trimmed) return "会话"
  return trimmed
    .replace(/^conv[_-]/, "")
    .replace(/[_]+/g, " ")
    .replace(/\s+/g, " ")
    .replace(/\b([a-z])/g, (match) => match.toUpperCase())
}

export function createOptionsFor(
  socialware: SocialwareRow,
  choices: Record<string, RoleSlotChoice>,
): CreateOptions {
  const roleSlots = (socialware.roles || [])
    .filter((role) => role.fill === "agent")
    .map((role) => {
      const choice = choices[role.role_name] || {
        role_name: role.role_name,
        mode: "fresh",
        flavor: role.flavor || undefined,
      }

      return {
        role_name: role.role_name,
        mode: choice.mode,
        flavor: choice.mode === "fresh" ? choice.flavor || role.flavor || undefined : undefined,
        agent_uri: choice.mode === "reuse" ? choice.agent_uri : undefined,
      }
    })
    .filter((choice) => choice.mode === "fresh" || Boolean(choice.agent_uri))

  return {
    role_slots: roleSlots,
    socialware_config_id: socialware.config_id || undefined,
    socialware_content_hash: socialware.content_hash || undefined,
  }
}

function AgentRoleSlot({
  role,
  choice,
  onChange,
}: {
  role: SocialwareRole
  choice?: RoleSlotChoice
  onChange: (choice: RoleSlotChoice) => void
}) {
  const current = choice || {role_name: role.role_name, mode: "fresh", flavor: role.flavor || undefined}
  const options = role.agent_options || []

  return (
    <div className="grid gap-2 rounded-md border border-border bg-background p-2" data-world-agent-role-slot={role.role_name}>
      <div className="flex min-w-0 items-center gap-2">
        <Bot className="h-4 w-4 flex-none text-muted-foreground" aria-hidden="true" />
        <div className="min-w-0 flex-1">
          <p className="truncate text-xs font-semibold text-foreground">{role.role_name}</p>
          <p className="truncate text-[11px] text-muted-foreground">{role.recipe || "recipe"} · {role.flavor || "default"}</p>
        </div>
      </div>
      <div className="grid grid-cols-2 gap-1 rounded-md border border-border bg-muted p-1" aria-label={`${role.role_name} install mode`}>
        {(["fresh", "reuse"] as const).map((mode) => (
          <button
            key={mode}
            type="button"
            className={
              current.mode === mode
                ? "rounded bg-background px-2 py-1 text-xs font-semibold text-foreground shadow-sm"
                : "rounded px-2 py-1 text-xs font-medium text-muted-foreground"
            }
            disabled={mode === "reuse" && options.length === 0}
            onClick={() =>
              onChange({
                ...current,
                mode,
                agent_uri: mode === "reuse" ? current.agent_uri || options[0]?.uri : undefined,
              })
            }
          >
            {mode === "fresh" ? "Fresh" : "Reuse"}
          </button>
        ))}
      </div>
      {current.mode === "fresh" ? (
        <label className="grid gap-1 text-[11px] font-medium text-muted-foreground" htmlFor={`role-flavor-${role.role_name}`}>
          Flavor
          <Input
            id={`role-flavor-${role.role_name}`}
            value={current.flavor || ""}
            onChange={(event) => onChange({...current, flavor: event.target.value})}
            placeholder={role.flavor || "default"}
          />
        </label>
      ) : (
        <label className="grid gap-1 text-[11px] font-medium text-muted-foreground" htmlFor={`role-agent-${role.role_name}`}>
          Agent
          <Select
            id={`role-agent-${role.role_name}`}
            value={current.agent_uri || options[0]?.uri || ""}
            onChange={(event) => onChange({...current, mode: "reuse", agent_uri: event.target.value})}
          >
            {options.map((agent) => (
              <option key={agent.uri} value={agent.uri}>
                {agent.display_name || agent.uri}
              </option>
            ))}
          </Select>
        </label>
      )}
    </div>
  )
}

function HumanRoleSlot({role}: {role: SocialwareRole}) {
  return (
    <div className="flex min-w-0 items-center gap-2 rounded-md border border-dashed border-border bg-background p-2" data-world-human-role-slot={role.role_name}>
      <UserRound className="h-4 w-4 flex-none text-muted-foreground" aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <p className="truncate text-xs font-semibold text-foreground">{role.role_name}</p>
        <p className="truncate text-[11px] text-muted-foreground">Open human slot</p>
      </div>
    </div>
  )
}

function DetailBlock({label, value, mono = false}: {label: string; value: string; mono?: boolean}) {
  return (
    <div className="rounded-md border border-border bg-background p-3">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={mono ? "mt-1 break-all font-mono text-xs text-foreground" : "mt-1 break-all text-sm text-foreground"}>
        {value}
      </p>
    </div>
  )
}
