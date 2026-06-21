import React from "react"
import {ArrowRight, Circle, Plus, X} from "lucide-react"

import {Button} from "./ui/primitives"

type SessionRow = {
  uri: string
  name?: string | null
  workspace_uri?: string | null
}

type SessionsState = {
  current_session_uri?: string | null
  sessions?: SessionRow[]
  workspace_uri?: string | null
}

type SessionsTableProps = {
  state?: SessionsState
  onJoin?: (sessionUri: string) => void
  onCreate?: (shortName: string, templateName: string) => void
}

export function SessionsTable({state, onJoin, onCreate}: SessionsTableProps) {
  const sessions = state?.sessions || []
  const currentSessionUri = state?.current_session_uri
  const [creating, setCreating] = React.useState(false)
  const [shortName, setShortName] = React.useState("")
  const [templateName, setTemplateName] = React.useState("default")

  const submit = (event: React.FormEvent) => {
    event.preventDefault()
    const trimmed = shortName.trim()
    const template = templateName.trim() || "default"
    if (!trimmed) return
    onCreate?.(trimmed, template)
    setShortName("")
    setTemplateName("default")
    setCreating(false)
  }

  return (
    <section className="world-section" aria-labelledby="sessions-title" data-world-component="sessions_table">
      <div className="world-section-header">
        <div>
          <h2 id="sessions-title">Session activity</h2>
          <p>Rendered by React from LiveView state.</p>
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

      {creating && (
        <form className="world-session-create" id="world-session-create-form" onSubmit={submit}>
          <label htmlFor="world-session-short-name">Name</label>
          <input
            id="world-session-short-name"
            value={shortName}
            onChange={(event) => setShortName(event.target.value)}
            placeholder="support-triage"
            autoFocus
          />
          <label htmlFor="world-session-template">Template</label>
          <input
            id="world-session-template"
            value={templateName}
            onChange={(event) => setTemplateName(event.target.value)}
            placeholder="default"
          />
          <Button type="submit" size="sm" disabled={!shortName.trim()}>
            <Plus aria-hidden="true" />
            Create
          </Button>
        </form>
      )}

      <div className="world-table-wrap">
        <table className="world-table">
          <thead>
            <tr>
              <th>Session</th>
              <th>Workspace</th>
              <th>Status</th>
              <th aria-label="Actions" />
            </tr>
          </thead>
          <tbody>
            {sessions.length === 0 ? (
              <tr>
                <td colSpan={4} className="world-empty">
                  No sessions in this workspace.
                </td>
              </tr>
            ) : (
              sessions.map((session) => {
                const active = session.uri === currentSessionUri

                return (
                  <tr key={session.uri} data-active={active ? "true" : "false"}>
                    <td>
                      <div className="world-session-cell">
                        <Circle className="world-status-icon" aria-hidden="true" />
                        <span>{session.uri}</span>
                      </div>
                    </td>
                    <td>{session.workspace_uri || "-"}</td>
                    <td>{active ? "Open" : "Available"}</td>
                    <td className="world-actions">
                      <Button size="sm" variant={active ? "secondary" : "default"} onClick={() => onJoin?.(session.uri)}>
                        <ArrowRight aria-hidden="true" />
                        Open
                      </Button>
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
