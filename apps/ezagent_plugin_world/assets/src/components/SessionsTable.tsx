import React from "react"
import {ArrowRight, Cable, Circle, Plus, X} from "lucide-react"

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
  const [shortName, setShortName] = React.useState("")
  const [templateName, setTemplateName] = React.useState(templates[0])

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
      className="min-w-0 max-w-full space-y-4 overflow-hidden rounded-lg border border-border bg-card p-5 text-card-foreground"
      aria-labelledby="sessions-title"
      data-world-component="sessions_table"
    >
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 id="sessions-title" className="text-lg font-semibold text-foreground">
            Session activity
          </h2>
          <p className="text-sm text-muted-foreground">本工作区的会话列表 —— 状态、外部镜像与快捷入口。</p>
        </div>
        <Button
          type="button"
          size="sm"
          variant={creating ? "secondary" : "default"}
          onClick={() => setCreating((open) => !open)}
          aria-label={creating ? "Close new session form" : "Create a new session"}
        >
          {creating ? <X aria-hidden="true" /> : <Plus aria-hidden="true" />}
          {creating ? "Close" : "New session"}
        </Button>
      </div>

      {state?.create_error && (
        <p
          className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
          role="alert"
          data-world-session-create-error
        >
          {state.create_error}
        </p>
      )}

      {creating && (
        <form
          className="grid gap-3 rounded-md border border-border bg-muted/30 p-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
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

      <div className="grid gap-2 sm:hidden">
        {sessions.length === 0 ? (
          <div className="rounded-md border border-border bg-muted/30 px-3 py-6 text-center text-sm text-muted-foreground">
            No sessions in this workspace.
          </div>
        ) : (
          sessions.map((session) => {
            const active = session.uri === currentSessionUri

            return (
              <article
                className="rounded-md border border-border bg-background p-3 data-[active=true]:bg-accent/40"
                data-active={active ? "true" : "false"}
                key={session.uri}
              >
                <div className="flex items-start gap-2">
                  <Circle className={active ? "mt-1 h-2 w-2 shrink-0 fill-[var(--ez-jade)] text-[var(--ez-jade)]" : "mt-1 h-2 w-2 shrink-0 fill-muted-foreground/40 text-muted-foreground/40"} aria-hidden="true" />
                  <div className="min-w-0 flex-1">
                    <code className="block break-all font-mono text-xs text-foreground">{session.uri}</code>
                    <div className="mt-2 grid gap-1 text-xs text-muted-foreground">
                      <span className="font-mono">{session.workspace_uri || "-"}</span>
                      <span>{active ? "Open" : "Available"}</span>
                    </div>
                  </div>
                </div>
                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <a
                    className="inline-flex items-center gap-1 rounded-md border border-border px-2 py-1 text-xs font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
                    href={`/admin/sessions/${encodeURIComponent(session.uri)}/external_mirror`}
                    title="Bind a Feishu chat to this session"
                  >
                    <Cable className="h-3.5 w-3.5" aria-hidden="true" />
                    External mirror
                  </a>
                  <Button size="sm" variant={active ? "secondary" : "default"} onClick={() => onJoin?.(session.uri)}>
                    <ArrowRight aria-hidden="true" />
                    Open
                  </Button>
                </div>
              </article>
            )
          })
        )}
      </div>

      <div className="hidden w-full max-w-full overflow-x-auto rounded-md border border-border sm:block">
        <table className="min-w-[760px] w-full border-collapse text-sm">
          <thead className="bg-muted/50 text-muted-foreground">
            <tr>
              <th className="px-3 py-2 text-left font-medium">Session</th>
              <th className="px-3 py-2 text-left font-medium">Workspace</th>
              <th className="px-3 py-2 text-left font-medium">Status</th>
              <th className="px-3 py-2 text-left font-medium" aria-label="Actions" />
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {sessions.length === 0 ? (
              <tr>
                <td colSpan={4} className="px-3 py-6 text-center text-muted-foreground">
                  No sessions in this workspace.
                </td>
              </tr>
            ) : (
              sessions.map((session) => {
                const active = session.uri === currentSessionUri

                return (
                  <tr key={session.uri} data-active={active ? "true" : "false"} className="hover:bg-muted/30 data-[active=true]:bg-accent/40">
                    <td className="px-3 py-2 align-top">
                      <div className="flex items-center gap-2">
                        <Circle className={active ? "h-2 w-2 fill-[var(--ez-jade)] text-[var(--ez-jade)]" : "h-2 w-2 fill-muted-foreground/40 text-muted-foreground/40"} aria-hidden="true" />
                        <span className="font-mono text-xs text-foreground">{session.uri}</span>
                      </div>
                    </td>
                    <td className="px-3 py-2 align-top font-mono text-xs text-muted-foreground">{session.workspace_uri || "-"}</td>
                    <td className="px-3 py-2 align-top">{active ? "Open" : "Available"}</td>
                    <td className="px-3 py-2 text-right align-top">
                      <div className="flex items-center justify-end gap-2">
                        <a
                          className="inline-flex items-center gap-1 rounded-md border border-border px-2 py-1 text-xs font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
                          href={`/admin/sessions/${encodeURIComponent(session.uri)}/external_mirror`}
                          title="Bind a Feishu chat to this session"
                        >
                          <Cable className="h-3.5 w-3.5" aria-hidden="true" />
                          External mirror
                        </a>
                        <Button size="sm" variant={active ? "secondary" : "default"} onClick={() => onJoin?.(session.uri)}>
                          <ArrowRight aria-hidden="true" />
                          Open
                        </Button>
                      </div>
                    </td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
      </div>
    </section>
  )
}
