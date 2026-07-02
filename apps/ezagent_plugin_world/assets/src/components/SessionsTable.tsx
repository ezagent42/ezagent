import React from "react"
import {ArrowRight, Cable, Circle, MessageSquare, Plus, X} from "lucide-react"

import {Button, Input, Select} from "./ui/primitives"

type SessionRow = {
  uri: string
  name?: string | null
  workspace_uri?: string | null
}

type SessionsState = {
  current_session_uri?: string | null
  sessions?: SessionRow[]
  templates?: string[]
  workspace_uri?: string | null
  create_error?: string
}

type SessionsTableProps = {
  state?: SessionsState
  onJoin?: (sessionUri: string) => void
  onCreate?: (shortName: string, templateName: string) => void
}

export function SessionsTable({state, onJoin, onCreate}: SessionsTableProps) {
  const sessions = state?.sessions || []
  const currentSessionUri = state?.current_session_uri
  const templates = state?.templates && state.templates.length > 0 ? state.templates : ["default"]
  const [creating, setCreating] = React.useState(false)
  const [filter, setFilter] = React.useState("")
  const [shortName, setShortName] = React.useState("")
  const [templateName, setTemplateName] = React.useState(templates[0])
  const selectedSession =
    sessions.find((session) => session.uri === currentSessionUri) || sessions[0] || null

  React.useEffect(() => {
    if (!templates.includes(templateName)) setTemplateName(templates[0])
  }, [templateName, templates])

  const filteredSessions = filterSessions(sessions, filter)

  const submit = (event: React.FormEvent) => {
    event.preventDefault()
    const trimmed = shortName.trim()
    const template = templateName.trim() || "default"
    if (!trimmed) return
    onCreate?.(trimmed, template)
    setShortName("")
    setTemplateName(templates[0])
    setCreating(false)
  }

  return (
    <section
      className="grid h-full min-h-0 min-w-0 overflow-hidden border-y border-border bg-background text-foreground lg:grid-cols-[276px_minmax(430px,1fr)_260px]"
      aria-labelledby="sessions-title"
      data-world-chat-default
      data-world-component="sessions_table"
    >
      <aside className="flex min-h-0 min-w-0 flex-col border-b border-border bg-card lg:border-b-0 lg:border-r" aria-label="Sessions" data-world-session-rail>
        <div className="flex items-center justify-between gap-2 border-b border-border px-3 py-3">
          <div className="min-w-0">
            <h2 id="sessions-title" className="truncate text-sm font-semibold text-foreground">
              Sessions
            </h2>
            <p className="text-xs text-muted-foreground">Current workspace only</p>
          </div>
          <Button
            type="button"
            size="icon"
            variant={creating ? "secondary" : "default"}
            onClick={() => setCreating((open) => !open)}
            aria-label={creating ? "Close new session form" : "Create a new session"}
          >
            {creating ? <X aria-hidden="true" /> : <Plus aria-hidden="true" />}
          </Button>
        </div>

        <div className="border-b border-border px-3 py-3">
          <Input
            aria-label="Filter sessions"
            value={filter}
            onChange={(event) => setFilter(event.target.value)}
            placeholder="Filter sessions, template, status"
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
            onSubmit={submit}
          >
            <label className="grid gap-1 text-xs font-medium text-muted-foreground" htmlFor="world-session-short-name">
              Name
              <Input
                id="world-session-short-name"
                value={shortName}
                onChange={(event) => setShortName(event.target.value)}
                placeholder="support-triage"
                autoFocus
              />
            </label>
            <label className="grid gap-1 text-xs font-medium text-muted-foreground" htmlFor="world-session-template">
              Template
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
            <Button type="submit" size="sm" disabled={!shortName.trim()}>
              <Plus aria-hidden="true" />
              Create
            </Button>
          </form>
        )}

        <div className="min-h-0 flex-1 space-y-1 overflow-y-auto p-2">
          {filteredSessions.length === 0 ? (
            <div className="rounded-md border border-dashed border-border bg-background px-3 py-6 text-center text-sm text-muted-foreground">
              No sessions in this workspace.
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
                  <span className="block truncate font-mono text-[11px] text-muted-foreground">{session.uri}</span>
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
              {selectedSession ? displaySessionName(selectedSession) : "Chat"}
            </h3>
            <p className="truncate font-mono text-xs text-muted-foreground">
              {selectedSession?.uri || state?.workspace_uri || "No session selected"}
            </p>
          </div>
          <div className="inline-flex rounded-[10px] border border-border bg-muted p-[3px]" aria-label="Session view">
            {["Chat", "PTY", "Preview"].map((item) => (
              <span
                key={item}
                className={
                  item === "Chat"
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
                {selectedSession ? "Open this session to load the conversation" : "Create or select a session"}
              </h4>
              <p className="mt-1 text-sm text-muted-foreground">
                Chat opens in the same three-column layout with the timeline, composer, members, routing, and tools drawer.
              </p>
            </div>
            {selectedSession && (
              <Button type="button" onClick={() => onJoin?.(selectedSession.uri)}>
                <ArrowRight aria-hidden="true" />
                Open conversation
              </Button>
            )}
          </div>
        </div>
      </main>

      <aside className="flex min-h-0 min-w-0 flex-col border-t border-border bg-card lg:border-l lg:border-t-0" aria-label="Session drawer">
        <div className="border-b border-border px-4 py-3">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Session</p>
          <h3 className="truncate text-sm font-semibold text-foreground">
            {selectedSession ? displaySessionName(selectedSession) : "No session"}
          </h3>
        </div>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
          <DetailBlock label="Workspace" value={selectedSession?.workspace_uri || state?.workspace_uri || "—"} />
          <DetailBlock label="URI" value={selectedSession?.uri || "—"} mono />

          <div className="space-y-2">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Actions</p>
            {selectedSession ? (
              <div className="grid gap-2">
                <Button type="button" variant="secondary" onClick={() => onJoin?.(selectedSession.uri)}>
                  <ArrowRight aria-hidden="true" />
                  Open
                </Button>
                <a
                  className="inline-flex min-h-9 items-center justify-center gap-2 rounded-full border border-border bg-card px-3 text-sm font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
                  href={`/admin/sessions/${encodeURIComponent(selectedSession.uri)}/external_mirror`}
                  title="Bind a Feishu chat to this session"
                >
                  <Cable className="h-4 w-4" aria-hidden="true" />
                  External mirror
                </a>
              </div>
            ) : (
              <p className="text-sm text-muted-foreground">No actions available.</p>
            )}
          </div>
        </div>
      </aside>
    </section>
  )
}

function filterSessions(sessions: SessionRow[], filter: string): SessionRow[] {
  const q = filter.trim().toLowerCase()
  if (!q) return sessions

  return sessions.filter((session) =>
    [session.uri, session.name, session.workspace_uri]
      .filter(Boolean)
      .some((value) => String(value).toLowerCase().includes(q)),
  )
}

function displaySessionName(session: SessionRow): string {
  if (session.name && session.name.trim()) return session.name

  const parts = session.uri.split("/")
  return parts[parts.length - 1] || session.uri
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
