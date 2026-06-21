import type React from "react"
import {Activity, Database, Route, Settings, ShieldCheck, TableProperties} from "lucide-react"

type AdminState = {
  audit_rows?: Record<string, unknown>[]
  bindings?: Record<string, unknown>[]
  bridges?: Record<string, unknown>[]
  cc_orchestrator_status?: unknown
  component?: string
  default_grants?: Record<string, unknown>[]
  entities?: Record<string, unknown>[]
  external_mirror_bindings?: Record<string, unknown>[]
  grantable?: unknown[]
  kpis?: Record<string, number>
  path?: string
  rules?: Record<string, unknown>[]
  session_uri?: string | null
  settings?: Record<string, unknown>
  snapshots?: Record<string, unknown>[]
  templates?: Record<string, unknown>[]
  title?: string
  workspace_uri?: string | null
}

export function AdminSurface({state}: {state: AdminState}) {
  switch (state.component) {
    case "observability":
      return <Observability state={state} />
    case "entity_registry":
      return <DataTable component="entity_registry" title="Entity registry" rows={state.entities || []} />
    case "snapshots":
      return <DataTable component="snapshots" title="Snapshots" rows={state.snapshots || []} />
    case "templates":
      return <DataTable component="templates" title="Templates" rows={state.templates || []} />
    case "caps_admin":
      return <CapsAdmin state={state} />
    case "authz_audit":
      return <DataTable component="authz_audit" title="Authz audit" rows={state.audit_rows || []} />
    case "settings":
      return <SettingsPanel state={state} />
    case "routing":
      return <RoutingPanel state={state} />
    case "external_mirror":
      return <ExternalMirror state={state} />
    default:
      return <Dashboard state={state} />
  }
}

function Dashboard({state}: {state: AdminState}) {
  const kpis = state.kpis || {}

  return (
    <section className="world-section" data-world-component="dashboard">
      <Header eyebrow="Admin" title="Dashboard" />
      <div className="world-kpi-grid">
        <Kpi icon={<Database />} label="Kinds" value={kpis.kinds} />
        <Kpi icon={<Activity />} label="Sessions" value={kpis.sessions} />
        <Kpi icon={<ShieldCheck />} label="Entities" value={kpis.entities} />
        <Kpi icon={<Route />} label="Agents" value={kpis.agents} />
      </div>
      <pre className="world-json">{JSON.stringify({cc_orchestrator_status: state.cc_orchestrator_status}, null, 2)}</pre>
    </section>
  )
}

function Observability({state}: {state: AdminState}) {
  return (
    <section className="world-section" data-world-component="observability">
      <Header eyebrow="Runtime" title="Observability" />
      <div className="world-kpi-grid">
        <Kpi icon={<Activity />} label="Audit rows" value={(state.audit_rows || []).length} />
        <Kpi icon={<Database />} label="Snapshots" value={(state.snapshots || []).length} />
        <Kpi icon={<ShieldCheck />} label="Bridges" value={(state.bridges || []).length} />
      </div>
      <DataTable component="observability-audit" title="Recent audit" rows={state.audit_rows || []} nested />
    </section>
  )
}

function CapsAdmin({state}: {state: AdminState}) {
  const rows = [
    ...((state.grantable || []) as unknown[]).map((entry) => ({type: "grantable", value: entry})),
    ...((state.default_grants || []) as unknown[]).map((entry) => ({type: "default", value: entry})),
  ]

  return <DataTable component="caps_admin" title="Capabilities" rows={rows} />
}

function SettingsPanel({state}: {state: AdminState}) {
  return (
    <section className="world-section" data-world-component="settings">
      <Header eyebrow="Config" title="Settings" icon={<Settings />} />
      <pre className="world-json">{JSON.stringify(state.settings || {}, null, 2)}</pre>
    </section>
  )
}

function RoutingPanel({state}: {state: AdminState}) {
  return (
    <section className="world-section" data-world-component="routing">
      <Header eyebrow="Routing" title="Routing" icon={<Route />} />
      <DataTable component="routing-rules" title="Mention routing rules" rows={state.rules || []} nested />
      <DataTable component="routing-external-mirror" title="External mirror bindings" rows={state.external_mirror_bindings || []} nested />
    </section>
  )
}

function ExternalMirror({state}: {state: AdminState}) {
  return (
    <section className="world-section" data-world-component="external_mirror">
      <Header eyebrow="Session" title="External mirror" />
      <p className="world-uri">{state.session_uri}</p>
      <DataTable component="external-mirror-bindings" title="Bindings" rows={state.bindings || []} nested />
    </section>
  )
}

function DataTable({
  component,
  title,
  rows,
  nested = false,
}: {
  component: string
  title: string
  rows: Record<string, unknown>[]
  nested?: boolean
}) {
  const columns = Array.from(new Set(rows.flatMap((row) => Object.keys(row)))).slice(0, 6)

  return (
    <section className={nested ? "world-subsection" : "world-section"} data-world-component={component}>
      <Header eyebrow="Table" title={title} icon={<TableProperties />} compact={nested} />
      <div className="world-table-wrap">
        <table className="world-table">
          <thead>
            <tr>
              {(columns.length > 0 ? columns : ["value"]).map((column) => (
                <th key={column}>{column}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, index) => (
              <tr key={index}>
                {(columns.length > 0 ? columns : ["value"]).map((column) => (
                  <td key={column}>
                    <Cell value={columns.length > 0 ? row[column] : row} />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <div className="world-empty">No rows.</div>}
      </div>
    </section>
  )
}

function Header({
  eyebrow,
  title,
  icon,
  compact = false,
}: {
  eyebrow: string
  title: string
  icon?: React.ReactNode
  compact?: boolean
}) {
  return (
    <div className={compact ? "world-section-header world-section-header-compact" : "world-section-header"}>
      <div>
        <p className="world-eyebrow">{eyebrow}</p>
        <h2>{title}</h2>
      </div>
      {icon}
    </div>
  )
}

function Kpi({icon, label, value}: {icon: React.ReactNode; label: string; value: number | undefined}) {
  return (
    <div className="world-kpi">
      {icon}
      <span>{label}</span>
      <strong>{value ?? 0}</strong>
    </div>
  )
}

function Cell({value}: {value: unknown}) {
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return <code>{String(value)}</code>
  }

  if (value == null) return <span className="world-muted-cell">null</span>

  return <code>{JSON.stringify(value)}</code>
}
