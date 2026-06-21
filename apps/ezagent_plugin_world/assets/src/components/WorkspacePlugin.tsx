import React from "react"
import {BadgeCheck, Boxes, Cable, Layers, Pencil, Plug, Save, Trash2, UserRound, X} from "lucide-react"

type DataRow = Record<string, unknown>

export type WorkspacePluginState = {
  bindings?: DataRow[]
  auto_derive_notice?: string | null
  caps_count?: number
  caps_path?: string | null
  component?: string
  detail?: DataRow
  detail_error?: string
  display_name?: string | null
  editing_display_name?: boolean
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
  template_error?: string | null
  template_notice?: string | null
  title?: string
  uri?: string | null
  workspaces?: DataRow[]
  workspace_uri?: string | null
}

export function WorkspacePluginSurface({
  state,
  onAction = () => undefined,
}: {
  state: WorkspacePluginState
  onAction?: (action: string, args: Record<string, unknown>) => void
}) {
  switch (state.component) {
    case "workspace_detail":
      return <WorkspaceDetail state={state} onAction={onAction} />
    case "plugins":
      return <Plugins state={state} />
    case "profile":
      return <Profile state={state} onAction={onAction} />
    case "auto_derive":
      return <AutoDerive state={state} onAction={onAction} />
    case "feishu_bindings":
      return <FeishuBindings state={state} onAction={onAction} />
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

function WorkspaceDetail({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
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
      <section className="world-subsection" data-world-component="workspace-members">
        <Header eyebrow="List" title="Members" compact />
        <div className="world-list">
          {(state.members || []).map((member) => (
            <div className="world-list-row" key={member}>
              <code>{member}</code>
              <button
                className="world-icon-button"
                type="button"
                title="Remove member"
                onClick={() => onAction("workspace.member.remove", {member_uri: member})}
              >
                <Trash2 size={16} />
              </button>
            </div>
          ))}
          {(state.members || []).length === 0 && <Empty label="No entries." />}
        </div>
      </section>
      <SessionTemplatePanel state={state} onAction={onAction} />
      <DataTable component="workspace-routing" title="Routing rules" rows={state.routing_rules || []} nested />
    </section>
  )
}

function SessionTemplatePanel({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const [name, setName] = React.useState("")
  const [description, setDescription] = React.useState("")
  const [publicView, setPublicView] = React.useState(false)

  return (
    <section className="world-subsection" data-world-component="workspace-templates">
      <Header eyebrow="Config" title="Session templates" compact />
      {state.template_notice && <p className="world-notice">{state.template_notice}</p>}
      {state.template_error && <p className="world-error">{state.template_error}</p>}
      <form
        id="world-session-template-form"
        className="world-form-grid"
        onSubmit={(event) => {
          event.preventDefault()
          onAction("workspace.template.save", {
            template: {
              name,
              description,
              public_view: publicView,
            },
          })
        }}
      >
        <label>
          Name
          <input
            id="world-session-template-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="public-demo"
          />
        </label>
        <label>
          Description
          <input
            id="world-session-template-description"
            value={description}
            onChange={(event) => setDescription(event.target.value)}
            placeholder="Public customer-facing session"
          />
        </label>
        <label className="world-checkbox-row">
          <input
            id="world-session-template-public-view"
            type="checkbox"
            checked={publicView}
            onChange={(event) => setPublicView(event.target.checked)}
          />
          <span>Public socialware app</span>
        </label>
        <button className="world-button world-button-primary" type="submit">
          <Save size={16} />
          Save template
        </button>
      </form>
      <DataTable component="workspace-templates" title="Saved templates" rows={state.session_templates || []} nested />
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

function Profile({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const [displayName, setDisplayName] = React.useState(state.display_name || "")

  React.useEffect(() => {
    setDisplayName(state.display_name || "")
  }, [state.display_name])

  return (
    <section className="world-section" data-world-component="profile">
      <Header eyebrow="Profile" title={state.display_name || "Profile"} icon={<UserRound />} />
      <p className="world-uri">{state.entity_uri}</p>
      {state.editing_display_name ? (
        <form
          id="world-display-name-form"
          className="world-inline-form"
          onSubmit={(event) => {
            event.preventDefault()
            onAction("profile.display_name.save", {display_name: displayName})
          }}
        >
          <label>
            Display name
            <input value={displayName} onChange={(event) => setDisplayName(event.target.value)} />
          </label>
          <button className="world-icon-button" type="submit" title="Save display name">
            <Save size={16} />
          </button>
          <button
            className="world-icon-button"
            type="button"
            title="Cancel"
            onClick={() => onAction("profile.display_name.cancel", {})}
          >
            <X size={16} />
          </button>
        </form>
      ) : (
        <button
          id="world-edit-display-name"
          className="world-button world-button-default"
          type="button"
          onClick={() => onAction("profile.display_name.edit", {})}
        >
          <Pencil size={16} />
          Edit display name
        </button>
      )}
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

function AutoDerive({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  if (state.detail || state.detail_error) {
    const cascade = (state.detail?.credential_cascade || null) as Record<string, unknown> | null

    return (
      <section className="world-section" data-world-component="auto_derive">
        <Header eyebrow="Auto derive" title={`Kind ${state.kind || "unknown"}`} icon={<Layers />} />
        {state.detail_error && <p className="world-error">{state.detail_error}</p>}
        {state.auto_derive_notice && <p className="world-notice">{String(state.auto_derive_notice)}</p>}
        {cascade && <CredentialCascadePanel cascade={cascade} onAction={onAction} />}
        {state.detail && <pre className="world-json">{JSON.stringify(state.detail, null, 2)}</pre>}
      </section>
    )
  }

  return <DataTable component="auto_derive" title={`Kind ${state.kind || "unknown"}`} rows={state.instances || []} />
}

function FeishuBindings({
  state,
  onAction,
}: {
  state: WorkspacePluginState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const [openId, setOpenId] = React.useState("")
  const [userUri, setUserUri] = React.useState("")
  const rows = state.bindings || []

  return (
    <section className="world-section" data-world-component="feishu_bindings">
      <Header eyebrow="Feishu" title="User bindings" icon={<Cable />} />
      <form
        id="world-feishu-bind-form"
        className="world-inline-form"
        onSubmit={(event) => {
          event.preventDefault()
          onAction("feishu.bind", {open_id: openId, user_uri: userUri})
          setOpenId("")
          setUserUri("")
        }}
      >
        <label>
          open_id
          <input value={openId} onChange={(event) => setOpenId(event.target.value)} />
        </label>
        <label>
          user URI
          <input list="world-feishu-entity-options" value={userUri} onChange={(event) => setUserUri(event.target.value)} />
        </label>
        <datalist id="world-feishu-entity-options">
          {(state.entity_options || []).map((option, index) => {
            const row = option as Record<string, unknown>
            return <option key={index} value={String(row.value || row.uri || "")} />
          })}
        </datalist>
        <button className="world-button world-button-primary" type="submit">
          Bind
        </button>
      </form>
      <section className="world-subsection" data-world-component="feishu-bindings-table">
        <Header eyebrow="Table" title="Bindings" compact />
        <div className="world-table-wrap">
          <table className="world-table">
            <thead>
              <tr>
                <th>open_id</th>
                <th>user_uri</th>
                <th>bound_by</th>
                <th>bound_at</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={String(row.open_id)}>
                  <td><code>{String(row.open_id || "")}</code></td>
                  <td><code>{String(row.user_uri || "")}</code></td>
                  <td><code>{String(row.bound_by || "")}</code></td>
                  <td>{String(row.bound_at || "")}</td>
                  <td>
                    <button
                      className="world-icon-button"
                      type="button"
                      title="Unbind"
                      onClick={() => onAction("feishu.unbind", {open_id: String(row.open_id || "")})}
                    >
                      <Trash2 size={16} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {rows.length === 0 && <Empty label="No rows." />}
        </div>
      </section>
    </section>
  )
}

function CredentialCascadePanel({
  cascade,
  onAction,
}: {
  cascade: Record<string, unknown>
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const form = (cascade.form || {}) as Record<string, unknown>
  const [sourceUri, setSourceUri] = React.useState(String(form.source_uri || ""))
  const [flavor, setFlavor] = React.useState(String(form.flavor || ""))
  const layerStack = (cascade.layer_stack || []) as Record<string, unknown>[]
  const grant = cascade.grant as Record<string, unknown> | null

  React.useEffect(() => {
    const next = (cascade.form || {}) as Record<string, unknown>
    setSourceUri(String(next.source_uri || ""))
    setFlavor(String(next.flavor || ""))
  }, [cascade.form])

  return (
    <section id="credential-cascade-panel" className="world-subsection">
      <Header eyebrow="Credentials" title="Credential cascade" compact />
      <div className="world-kv-grid">
        <div><span>source</span><code>{String(cascade.credential_source_uri || "none")}</code></div>
        <div><span>default</span><code>{String(cascade.default_source_uri || "none")}</code></div>
        <div><span>flavor</span><code>{String(cascade.flavor || "")}</code></div>
      </div>
      <SimpleList title="Layer stack" values={layerStack.map((row) => `${String(row.level)}: ${String(row.source || "not selected")}`)} />
      {grant ? (
        <div id="credential-grant-row" className="world-kv-grid">
          <div><span>status</span><code>{String(grant.status || "")}</code></div>
          <div><span>approved by</span><code>{String(grant.approved_by || "")}</code></div>
          <div><span>version</span><code>{String(grant.version || "")}</code></div>
          <button
            id="revoke-credential-grant"
            className="world-button world-button-danger"
            type="button"
            onClick={() => onAction("auto_derive.credential_grant.revoke", {agent_uri: String(cascade.agent_uri || "")})}
          >
            Revoke grant
          </button>
        </div>
      ) : (
        <p className="world-muted-cell">No credential grant for this agent.</p>
      )}
      <form
        id="set-default-source-form"
        className="world-inline-form"
        onSubmit={(event) => {
          event.preventDefault()
          onAction("auto_derive.default_source.set", {
            default_source: {
              owner_uri: String(form.owner_uri || ""),
              workspace_uri: String(form.workspace_uri || ""),
              flavor,
              source_uri: sourceUri,
            },
          })
        }}
      >
        <label>
          Flavor
          <input value={flavor} onChange={(event) => setFlavor(event.target.value)} />
        </label>
        <label>
          Source URI
          <input value={sourceUri} onChange={(event) => setSourceUri(event.target.value)} />
        </label>
        <button className="world-button world-button-primary" type="submit">
          Set default source
        </button>
      </form>
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
