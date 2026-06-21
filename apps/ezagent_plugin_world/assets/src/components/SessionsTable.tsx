import {ArrowRight, Circle} from "lucide-react"

import {Button} from "./ui/button"

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
}

export function SessionsTable({state, onJoin}: SessionsTableProps) {
  const sessions = state?.sessions || []
  const currentSessionUri = state?.current_session_uri

  return (
    <div className="world-screen">
      <aside className="world-sidebar" aria-label="World navigation">
        <div className="world-mark">W</div>
        <nav className="world-nav">
          <a className="world-nav-item world-nav-item-active" href="/">
            Overview
          </a>
          <a className="world-nav-item" href="/sessions">
            Sessions
          </a>
        </nav>
      </aside>

      <main className="world-main">
        <header className="world-header">
          <div>
            <p className="world-eyebrow">React/shadcn shell</p>
            <h1>Sessions</h1>
          </div>
          <div className="world-scope">{state?.workspace_uri || "workspace://system"}</div>
        </header>

        <section className="world-section" aria-labelledby="sessions-title">
          <div className="world-section-header">
            <div>
              <h2 id="sessions-title">Session activity</h2>
              <p>Rendered by React from LiveView state.</p>
            </div>
          </div>

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
      </main>
    </div>
  )
}
