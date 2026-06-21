import type React from "react"
import {BadgeCheck, Boxes, Cable, Layers, Plug, UserRound} from "lucide-react"

type DataRow = Record<string, unknown>

export type WorkspacePluginState = {
  bindings?: DataRow[]
  caps_count?: number
  caps_path?: string | null
  component?: string
  detail?: DataRow
  detail_error?: string
  display_name?: string | null
  entity_options?: unknown[]
  entity_uri?: string | null
  error?: string
  instances?: DataRow[]
  kind?: string | null
  members?: string[]
  name?: string
  not_found?: boolean
  path?: string
  plugins?: DataRow[]
  routing_rules?: DataRow[]
  session_templates?: DataRow[]
  title?: string
  uri?: string | null
  workspaces?: DataRow[]
  workspace_uri?: string | null
}

export function WorkspacePluginSurface({state}: {state: WorkspacePluginState}) {
  switch (state.component) {
    case "workspace_detail":
      return <WorkspaceDetail state={state} />
    case "plugins":
      return <Plugins state={state} />
    case "profile":
      return <Profile state={state} />
    case "auto_derive":
      return <AutoDerive state={state} />
    case "feishu_bindings":
      return <FeishuBindings state={state} />
    default:
      return <Workspaces state={state} />
  }
}

function Workspaces({state}: {state: WorkspacePluginState}) {
  const rows = state.workspaces || []

  return (
    <section className="world-section" data-world-component="workspaces_list">
      <Header eyebrow="Workspace" title="Workspaces" icon={<Boxes />} />
      <div className="world-table-wrap">
        <table className="world-table" id="world-workspaces-table">
          <thead>
            <tr>
              <th>Name / URI</th>
              <th>Members</th>
              <th>Templates</th>
              <th>Rules</th>
              <th>Live</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={String(row.uri || row.name)}>
                <td>
                  <strong>
                    <a href={String(row.detail_path || "#")}>{String(row.name || row.uri)}</a>
                  </strong>
                  <code>{String(row.uri || "")}</code>
                </td>
                <td>{String(row.members_count ?? 0)}</td>
                <td>{String(row.templates_count ?? 0)}</td>
                <td>{String(row.routing_rules_count ?? 0)}</td>
                <td>{row.live ? "live" : "down"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <Empty label="No visible workspaces." />}
      </div>
    </section>
  )
}

function WorkspaceDetail({state}: {state: WorkspacePluginState}) {
  if (state.not_found) {
    return (
      <section className="world-section" data-world-component="workspace_detail">
        <Header eyebrow="Workspace" title="Workspace not found" icon={<Boxes />} />
        <p className="world-muted-cell">{String(state.name || state.path || "")}</p>
      </section>
    )
  }

  return (
    <section className="world-section" data-world-component="workspace_detail">
      <Header eyebrow="Workspace" title={String(state.name || "Workspace")} icon={<Boxes />} />
      <div className="world-kpi-grid">
        <Kpi icon={<UserRound />} label="Members" value={(state.members || []).length} />
        <Kpi icon={<Layers />} label="Templates" value={(state.session_templates || []).length} />
        <Kpi icon={<Cable />} label="Routing rules" value={(state.routing_rules || []).length} />
      </div>
      <p className="world-uri">{state.uri}</p>
      <SimpleList title="Members" values={state.members || []} />
      <DataTable component="workspace-templates" title="Session templates" rows={state.session_templates || []} nested />
      <DataTable component="workspace-routing" title="Routing rules" rows={state.routing_rules || []} nested />
    </section>
  )
}

function Plugins({state}: {state: WorkspacePluginState}) {
  const rows = state.plugins || []

  return (
    <section className="world-section" data-world-component="plugins">
      <Header eyebrow="Plugins" title="Installed plugins" icon={<Plug />} />
      <div className="world-card-grid">
        {rows.map((plugin) => (
          <article className="world-card" key={String(plugin.slug || plugin.name)}>
            <div className="world-card-title">{String(plugin.name || plugin.slug)}</div>
            <p>{String(plugin.description || "")}</p>
            <div className="world-inline-meta">
              <code>{String(plugin.version || "dev")}</code>
              {plugin.config_path ? (
                <a href={String(plugin.config_path)}>{String(plugin.config_label || "Configure")}</a>
              ) : (
                <span>no config</span>
              )}
            </div>
          </article>
        ))}
        {rows.length === 0 && <Empty label="No plugins registered." />}
      </div>
    </section>
  )
}

function Profile({state}: {state: WorkspacePluginState}) {
  return (
    <section className="world-section" data-world-component="profile">
      <Header eyebrow="Profile" title={state.display_name || "Profile"} icon={<UserRound />} />
      <p className="world-uri">{state.entity_uri}</p>
      <div className="world-kpi-grid">
        <Kpi icon={<BadgeCheck />} label="Capabilities" value={state.caps_count || 0} />
      </div>
      {state.caps_path && (
        <a className="world-button world-button-default world-button-link" href={state.caps_path}>
          View caps
        </a>
      )}
    </section>
  )
}

function AutoDerive({state}: {state: WorkspacePluginState}) {
  if (state.detail || state.detail_error) {
    return (
      <section className="world-section" data-world-component="auto_derive">
        <Header eyebrow="Auto derive" title={`Kind ${state.kind || "unknown"}`} icon={<Layers />} />
        {state.detail_error && <p className="world-error">{state.detail_error}</p>}
        {state.detail && <pre className="world-json">{JSON.stringify(state.detail, null, 2)}</pre>}
      </section>
    )
  }

  return <DataTable component="auto_derive" title={`Kind ${state.kind || "unknown"}`} rows={state.instances || []} />
}

function FeishuBindings({state}: {state: WorkspacePluginState}) {
  return (
    <section className="world-section" data-world-component="feishu_bindings">
      <Header eyebrow="Feishu" title="User bindings" icon={<Cable />} />
      <DataTable component="feishu-bindings-table" title="Bindings" rows={state.bindings || []} nested />
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
  rows: DataRow[]
  nested?: boolean
}) {
  const columns = Array.from(new Set(rows.flatMap((row) => Object.keys(row)))).slice(0, 6)

  return (
    <section className={nested ? "world-subsection" : "world-section"} data-world-component={component}>
      <Header eyebrow="Table" title={title} compact={nested} />
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
        {rows.length === 0 && <Empty label="No rows." />}
      </div>
    </section>
  )
}

function SimpleList({title, values}: {title: string; values: string[]}) {
  return (
    <section className="world-subsection">
      <Header eyebrow="List" title={title} compact />
      <div className="world-list">
        {values.map((value) => (
          <code key={value}>{value}</code>
        ))}
        {values.length === 0 && <Empty label="No entries." />}
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

function Kpi({icon, label, value}: {icon: React.ReactNode; label: string; value: number}) {
  return (
    <div className="world-kpi">
      {icon}
      <span>{label}</span>
      <strong>{value}</strong>
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

function Empty({label}: {label: string}) {
  return <div className="world-empty">{label}</div>
}
