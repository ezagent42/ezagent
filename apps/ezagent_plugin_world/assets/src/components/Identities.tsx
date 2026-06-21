import React from "react"
import {BadgeCheck, Layers, Plus, Shield, UserRound, UsersRound} from "lucide-react"

import {Button} from "./ui/button"

type IdentityRow = {
  uri: string
  kind?: string
  name?: string
  display_name?: string
  flavor?: string
  alive?: boolean
  caps_path?: string | null
  detail_path?: string | null
  api_keys_path?: string | null
  extensions_path?: string | null
}

type UserRow = {
  uri: string
  display_name?: string
  has_password?: boolean
  cap_count?: number
  online?: boolean
  transports?: string[]
  system_member?: boolean
  caps_path?: string | null
}

type CapRow = {
  kind?: string
  behavior?: string
  action?: string
  instance?: string
  workspace_uri?: string | null
  granted_by?: string | null
}

type ApiKeyRow = {
  provider?: string
  masked?: string
}

type ExtensionRow = {
  id?: string
  name?: string
  description?: string
  enabled?: boolean
}

export type IdentitiesState = {
  agent_flavors?: string[]
  agent_status?: Record<string, unknown>
  agent_uri?: string | null
  agents?: IdentityRow[]
  api_keys?: ApiKeyRow[] | {error?: string}
  bridge?: Record<string, unknown> | null
  can_edit?: boolean
  caps?: CapRow[] | {error?: string}
  component?: string
  config_dir_path?: string | null
  creator_uri?: string | null
  default_flavor?: string
  entity_kind?: string
  entity_uri?: string | null
  entities?: IdentityRow[]
  error?: string
  extensions?: ExtensionRow[]
  filter?: string
  flavors?: string[]
  notice?: string
  path?: string
  preview_uri?: string
  title?: string
  users?: UserRow[]
  workspace_uri?: string | null
}

type Props = {
  state: IdentitiesState
  onCreateAgent?: (payload: Record<string, unknown>) => void
}

export function IdentitiesSurface({state, onCreateAgent}: Props) {
  if (state.component === "users_table") return <UsersTable state={state} />
  if (state.component === "agents_table") return <AgentsTable state={state} />
  if (state.component === "entity_caps") return <EntityCaps state={state} />
  if (state.component === "agent_detail") return <AgentDetail state={state} />
  if (state.component === "agent_new_form") return <AgentNewForm state={state} onCreateAgent={onCreateAgent} />
  if (state.component === "agent_api_keys") return <AgentApiKeys state={state} />
  if (state.component === "agent_extensions") return <AgentExtensions state={state} />
  return <IdentityDirectory state={state} />
}

function IdentityDirectory({state}: {state: IdentitiesState}) {
  const rows = state.entities || []

  return (
    <section className="world-section world-identities" data-world-component="identities" aria-labelledby="identities-title">
      <SectionHeader
        eyebrow="Directory"
        title="Identities"
        actions={
          <a className="world-button world-button-default world-button-link" href="/identities/agents/new">
            <Plus aria-hidden="true" />
            New agent
          </a>
        }
      />

      <FilterBar active={state.filter || "all"} flavors={state.agent_flavors || []} />

      <div className="world-card-grid">
        {rows.map((row) => (
          <IdentityCard key={row.uri} row={row} />
        ))}
        {rows.length === 0 && <Empty label="No identities match this filter." />}
      </div>
    </section>
  )
}

function UsersTable({state}: {state: IdentitiesState}) {
  const users = state.users || []

  return (
    <section className="world-section" data-world-component="users_table" aria-labelledby="users-title">
      <SectionHeader eyebrow="Principals" title="Users" />
      <div className="world-table-wrap">
        <table className="world-table" id="world-users-table">
          <thead>
            <tr>
              <th>Name / URI</th>
              <th>Password</th>
              <th>Caps</th>
              <th>System</th>
              <th>Presence</th>
            </tr>
          </thead>
          <tbody>
            {users.map((user) => (
              <tr key={user.uri}>
                <td>
                  <strong>{user.display_name || user.uri}</strong>
                  <code>{user.uri}</code>
                </td>
                <td>{user.has_password ? "set" : "unset"}</td>
                <td>
                  <a href={user.caps_path || "#"}>{user.cap_count || 0}</a>
                </td>
                <td>{user.system_member ? "system" : "workspace"}</td>
                <td>{user.online ? `online ${formatList(user.transports)}` : "offline"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {users.length === 0 && <Empty label="No users." />}
      </div>
    </section>
  )
}

function AgentsTable({state}: {state: IdentitiesState}) {
  const agents = state.agents || []

  return (
    <section className="world-section" data-world-component="agents_table" aria-labelledby="agents-title">
      <SectionHeader
        eyebrow="Agents"
        title="Agents"
        actions={
          <a className="world-button world-button-default world-button-link" href="/identities/agents/new">
            <Plus aria-hidden="true" />
            New agent
          </a>
        }
      />
      <div className="world-table-wrap">
        <table className="world-table" id="world-agents-table">
          <thead>
            <tr>
              <th>Name / URI</th>
              <th>Flavor</th>
              <th>Status</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {agents.map((agent) => (
              <tr key={agent.uri}>
                <td>
                  <strong>{agent.display_name || agent.name || agent.uri}</strong>
                  <code>{agent.uri}</code>
                </td>
                <td>{agent.flavor || "unknown"}</td>
                <td>{agent.alive ? "live" : "registered"}</td>
                <td>
                  <InlineLinks
                    links={[
                      ["Status", agent.detail_path],
                      ["Caps", agent.caps_path],
                      ["API Keys", agent.api_keys_path],
                      ["Extensions", agent.extensions_path],
                    ]}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {agents.length === 0 && <Empty label="No agents in this workspace." />}
      </div>
    </section>
  )
}

function EntityCaps({state}: {state: IdentitiesState}) {
  const caps = Array.isArray(state.caps) ? state.caps : []
  const error = !Array.isArray(state.caps) ? state.caps?.error : undefined

  return (
    <section className="world-section" data-world-component="entity_caps" aria-labelledby="caps-title">
      <SectionHeader eyebrow={state.entity_kind || "entity"} title="Entity caps" />
      <p className="world-uri">{state.entity_uri}</p>
      {error && <p className="world-alert">{error}</p>}
      <div className="world-table-wrap">
        <table className="world-table" id="world-caps-table">
          <thead>
            <tr>
              <th>kind</th>
              <th>behavior</th>
              <th>action</th>
              <th>instance</th>
              <th>granted by</th>
            </tr>
          </thead>
          <tbody>
            {caps.map((cap, index) => (
              <tr key={`${cap.kind}-${cap.behavior}-${index}`}>
                <td>{cap.kind}</td>
                <td>{cap.behavior}</td>
                <td>{cap.action}</td>
                <td>
                  <code>{cap.instance}</code>
                </td>
                <td>
                  <code>{cap.granted_by}</code>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {caps.length === 0 && !error && <Empty label="No caps." />}
      </div>
    </section>
  )
}

function AgentDetail({state}: {state: IdentitiesState}) {
  const status = state.agent_status || {}

  return (
    <section className="world-section" data-world-component="agent_detail" aria-labelledby="agent-detail-title">
      <SectionHeader eyebrow="Agent" title="Agent detail" />
      <p className="world-uri">{state.agent_uri}</p>
      <div className="world-kpi-grid">
        <Kpi icon={<BadgeCheck />} label="Phase" value={String(status.phase || "unknown")} />
        <Kpi icon={<Layers />} label="Flavor" value={String(status.flavor || "unknown")} />
        <Kpi icon={<Shield />} label="Bridge" value={state.bridge ? "connected" : "not connected"} />
      </div>
      <pre className="world-json">{JSON.stringify(status.detail || status, null, 2)}</pre>
    </section>
  )
}

function AgentNewForm({state, onCreateAgent}: {state: IdentitiesState; onCreateAgent?: (payload: Record<string, unknown>) => void}) {
  const [form, setForm] = React.useState({
    flavor: state.default_flavor || state.flavors?.[0] || "cc",
    name: "",
    cwd: "",
    caps: "",
    with_pty: false,
  })
  const preview = form.name ? previewAgentUri(state.workspace_uri, form.name) : state.preview_uri || "<agent-uri>"

  return (
    <section className="world-section" data-world-component="agent_new_form" aria-labelledby="agent-new-title">
      <SectionHeader eyebrow="Provision" title="New agent" />
      <form
        id="world-agent-new-form"
        className="world-form"
        onSubmit={(event) => {
          event.preventDefault()
          onCreateAgent?.(form)
        }}
      >
        <label>
          <span>Flavor</span>
          <select value={form.flavor} onChange={(event) => setForm({...form, flavor: event.target.value})}>
            {(state.flavors || [form.flavor]).map((flavor) => (
              <option key={flavor} value={flavor}>
                {flavor}
              </option>
            ))}
          </select>
        </label>
        <label>
          <span>Name</span>
          <input value={form.name} onChange={(event) => setForm({...form, name: event.target.value})} placeholder="demo-agent" />
        </label>
        <label>
          <span>CWD</span>
          <input value={form.cwd} onChange={(event) => setForm({...form, cwd: event.target.value})} placeholder="/tmp" />
        </label>
        <label>
          <span>Initial caps</span>
          <input value={form.caps} onChange={(event) => setForm({...form, caps: event.target.value})} placeholder="chat.send, workspace.read" />
        </label>
        <label className="world-checkbox">
          <input
            type="checkbox"
            checked={form.with_pty}
            onChange={(event) => setForm({...form, with_pty: event.target.checked})}
          />
          <span>With PTY</span>
        </label>
        <div className="world-form-footer">
          <code>{preview}</code>
          <Button type="submit">
            <Plus aria-hidden="true" />
            Create
          </Button>
        </div>
      </form>
    </section>
  )
}

function AgentApiKeys({state}: {state: IdentitiesState}) {
  const keys = Array.isArray(state.api_keys) ? state.api_keys : []
  const error = !Array.isArray(state.api_keys) ? state.api_keys?.error : undefined

  return (
    <section className="world-section" data-world-component="agent_api_keys" aria-labelledby="api-keys-title">
      <SectionHeader eyebrow="Secrets" title="Agent API keys" />
      <p className="world-uri">{state.agent_uri}</p>
      {error && <p className="world-alert">{error}</p>}
      <div className="world-table-wrap">
        <table className="world-table" id="world-api-keys-table">
          <thead>
            <tr>
              <th>Provider</th>
              <th>Masked</th>
            </tr>
          </thead>
          <tbody>
            {keys.map((key) => (
              <tr key={key.provider}>
                <td>{key.provider}</td>
                <td>
                  <code>{key.masked}</code>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {keys.length === 0 && !error && <Empty label="No stored keys." />}
      </div>
    </section>
  )
}

function AgentExtensions({state}: {state: IdentitiesState}) {
  const extensions = state.extensions || []

  return (
    <section className="world-section" data-world-component="agent_extensions" aria-labelledby="agent-extensions-title">
      <SectionHeader eyebrow="Extensions" title="Agent extensions" />
      <p className="world-uri">{state.agent_uri}</p>
      {state.error && <p className="world-alert">{state.error}</p>}
      {state.notice && <p className="world-note">{state.notice}</p>}
      <div className="world-card-grid">
        {extensions.map((extension) => (
          <article className="world-mini-card" key={extension.id || extension.name}>
            <strong>{extension.name || extension.id}</strong>
            <p>{extension.description || "No description."}</p>
            <span>{extension.enabled ? "enabled" : "disabled"}</span>
          </article>
        ))}
        {extensions.length === 0 && <Empty label="No extensions available." />}
      </div>
    </section>
  )
}

function SectionHeader({eyebrow, title, actions}: {eyebrow: string; title: string; actions?: React.ReactNode}) {
  return (
    <div className="world-section-header">
      <div>
        <p className="world-eyebrow">{eyebrow}</p>
        <h2>{title}</h2>
      </div>
      {actions}
    </div>
  )
}

function IdentityCard({row}: {row: IdentityRow}) {
  return (
    <article className="world-mini-card">
      <div className="world-card-heading">
        {row.kind === "agent" ? <UsersRound aria-hidden="true" /> : <UserRound aria-hidden="true" />}
        <div>
          <strong>{row.display_name || row.name || row.uri}</strong>
          <code>{row.uri}</code>
        </div>
      </div>
      <p>{row.kind === "agent" ? `Agent ${row.flavor || "unknown"}` : "User"}</p>
      <InlineLinks
        links={[
          ["Status", row.detail_path],
          ["Caps", row.caps_path],
          ["API Keys", row.api_keys_path],
        ]}
      />
    </article>
  )
}

function FilterBar({active, flavors}: {active: string; flavors: string[]}) {
  const filters = [
    ["All", "/identities"],
    ["Users", "/identities/users"],
    ["Agents", "/identities/agents"],
    ...flavors.map((flavor) => [`agent:${flavor}`, `/identities?filter=${encodeURIComponent(`agent:${flavor}`)}`]),
  ]

  return (
    <div className="world-filter-bar">
      {filters.map(([label, href]) => (
        <a className={activeMatches(active, label) ? "world-filter-active" : ""} href={href} key={href}>
          {label}
        </a>
      ))}
    </div>
  )
}

function InlineLinks({links}: {links: Array<[string, string | null | undefined]>}) {
  return (
    <div className="world-inline-links">
      {links
        .filter(([, href]) => Boolean(href))
        .map(([label, href]) => (
          <a href={href || "#"} key={label}>
            {label}
          </a>
        ))}
    </div>
  )
}

function Kpi({icon, label, value}: {icon: React.ReactNode; label: string; value: string}) {
  return (
    <div className="world-kpi">
      {icon}
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

function Empty({label}: {label: string}) {
  return <div className="world-empty">{label}</div>
}

function activeMatches(active: string, label: string) {
  if (label === "All") return active === "all"
  if (label === "Users") return active === "users"
  if (label === "Agents") return active === "agents"
  return active === label
}

function previewAgentUri(workspaceUri: string | null | undefined, name: string) {
  const workspace = workspaceUri?.replace("workspace://", "") || "system"
  return `entity://agent/${workspace}/${name}`
}

function formatList(values: string[] | undefined) {
  if (!values || values.length === 0) return ""
  return `via ${values.join(", ")}`
}
