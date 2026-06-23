import React from "react"
import {BadgeCheck, Layers, Plus, Shield, UserRound, UsersRound} from "lucide-react"

import {Button, EmptyState, Input, Select, Stat} from "./ui/primitives"

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
  api_keys?: ApiKeyRow[] | {error?: string; unsupported?: boolean}
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
  cwd_required_flavors?: string[]
  cwd_required_with_pty_flavors?: string[]
  create_error?: string
}

type Props = {
  state: IdentitiesState
  onCreateAgent?: (payload: Record<string, unknown>) => void
}

// Shared shadcn token classes (consistent with the admin/sessions clusters).
const surfaceClass = "space-y-4 rounded-lg border border-border bg-card p-5 text-card-foreground"
const tableWrapClass = "overflow-x-auto rounded-md border border-border"
const tableClass = "w-full border-collapse text-sm"
const theadClass = "bg-muted/50 text-muted-foreground"
const tbodyClass = "divide-y divide-border"
const thClass = "px-3 py-2 text-left font-medium"
const tdClass = "px-3 py-2 align-top"
const rowClass = "hover:bg-muted/30"
const uriClass = "block w-fit rounded-md border border-border bg-muted/50 px-2 py-1 font-mono text-xs text-muted-foreground"
const codeClass = "font-mono text-xs text-muted-foreground"
const actionLinkClass =
  "inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground transition hover:opacity-90"

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
    <section className={surfaceClass} data-world-component="identities" aria-labelledby="identities-title">
      <SectionHeader
        eyebrow="Directory"
        title="Identities"
        actions={
          <a className={actionLinkClass} href="/identities/agents/new">
            <Plus aria-hidden="true" className="h-4 w-4" />
            New agent
          </a>
        }
      />

      <FilterBar active={state.filter || "all"} flavors={state.agent_flavors || []} />

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {rows.map((row) => (
          <IdentityCard key={row.uri} row={row} />
        ))}
        {rows.length === 0 && <EmptyState label="No identities match this filter." />}
      </div>
    </section>
  )
}

function UsersTable({state}: {state: IdentitiesState}) {
  const users = state.users || []

  return (
    <section className={surfaceClass} data-world-component="users_table" aria-labelledby="users-title">
      <SectionHeader eyebrow="Principals" title="Users" />
      <div className={tableWrapClass}>
        <table className={tableClass} id="world-users-table">
          <thead className={theadClass}>
            <tr>
              <th className={thClass}>Name / URI</th>
              <th className={thClass}>Password</th>
              <th className={thClass}>Caps</th>
              <th className={thClass}>System</th>
              <th className={thClass}>Presence</th>
            </tr>
          </thead>
          <tbody className={tbodyClass}>
            {users.map((user) => (
              <tr key={user.uri} className={rowClass}>
                <td className={tdClass}>
                  <strong className="block text-foreground">{user.display_name || user.uri}</strong>
                  <code className={codeClass}>{user.uri}</code>
                </td>
                <td className={tdClass}>{user.has_password ? "set" : "unset"}</td>
                <td className={tdClass}>
                  <a className="text-primary hover:underline" href={user.caps_path || "#"}>
                    {user.cap_count || 0}
                  </a>
                </td>
                <td className={tdClass}>{user.system_member ? "system" : "workspace"}</td>
                <td className={tdClass}>{user.online ? `online ${formatList(user.transports)}` : "offline"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {users.length === 0 && <EmptyState label="No users." />}
      </div>
    </section>
  )
}

function AgentsTable({state}: {state: IdentitiesState}) {
  const agents = state.agents || []

  return (
    <section className={surfaceClass} data-world-component="agents_table" aria-labelledby="agents-title">
      <SectionHeader
        eyebrow="Agents"
        title="Agents"
        actions={
          <a className={actionLinkClass} href="/identities/agents/new">
            <Plus aria-hidden="true" className="h-4 w-4" />
            New agent
          </a>
        }
      />
      <div className={tableWrapClass}>
        <table className={tableClass} id="world-agents-table">
          <thead className={theadClass}>
            <tr>
              <th className={thClass}>Name / URI</th>
              <th className={thClass}>Flavor</th>
              <th className={thClass}>Status</th>
              <th className={thClass}>Actions</th>
            </tr>
          </thead>
          <tbody className={tbodyClass}>
            {agents.map((agent) => (
              <tr key={agent.uri} className={rowClass}>
                <td className={tdClass}>
                  <strong className="block text-foreground">{agent.display_name || agent.name || agent.uri}</strong>
                  <code className={codeClass}>{agent.uri}</code>
                </td>
                <td className={tdClass}>{agent.flavor || "unknown"}</td>
                <td className={tdClass}>{agent.alive ? "live" : "registered"}</td>
                <td className={tdClass}>
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
        {agents.length === 0 && <EmptyState label="No agents in this workspace." />}
      </div>
    </section>
  )
}

function EntityCaps({state}: {state: IdentitiesState}) {
  const caps = Array.isArray(state.caps) ? state.caps : []
  const error = !Array.isArray(state.caps) ? state.caps?.error : undefined

  return (
    <section className={surfaceClass} data-world-component="entity_caps" aria-labelledby="caps-title">
      <SectionHeader eyebrow={state.entity_kind || "entity"} title="Entity caps" />
      <code className={uriClass}>{state.entity_uri}</code>
      {error && <p className="text-sm text-destructive">{error}</p>}
      <div className={tableWrapClass}>
        <table className={tableClass} id="world-caps-table">
          <thead className={theadClass}>
            <tr>
              <th className={thClass}>kind</th>
              <th className={thClass}>behavior</th>
              <th className={thClass}>action</th>
              <th className={thClass}>instance</th>
              <th className={thClass}>granted by</th>
            </tr>
          </thead>
          <tbody className={tbodyClass}>
            {caps.map((cap, index) => (
              <tr key={`${cap.kind}-${cap.behavior}-${index}`} className={rowClass}>
                <td className={tdClass}>{cap.kind}</td>
                <td className={tdClass}>{cap.behavior}</td>
                <td className={tdClass}>{cap.action}</td>
                <td className={tdClass}>
                  <code className={codeClass}>{cap.instance}</code>
                </td>
                <td className={tdClass}>
                  <code className={codeClass}>{cap.granted_by}</code>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {caps.length === 0 && !error && <EmptyState label="No caps." />}
      </div>
    </section>
  )
}

function AgentDetail({state}: {state: IdentitiesState}) {
  const status = state.agent_status || {}

  return (
    <section className={surfaceClass} data-world-component="agent_detail" aria-labelledby="agent-detail-title">
      <SectionHeader eyebrow="Agent" title="Agent detail" />
      <code className={uriClass}>{state.agent_uri}</code>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat icon={<BadgeCheck className="h-4 w-4" />} label="Phase" value={String(status.phase || "unknown")} />
        <Stat icon={<Layers className="h-4 w-4" />} label="Flavor" value={String(status.flavor || "unknown")} />
        <Stat icon={<Shield className="h-4 w-4" />} label="Bridge" value={state.bridge ? "connected" : "not connected"} />
      </div>
      <pre className="overflow-x-auto rounded-md border border-border bg-muted/40 p-3 text-xs text-muted-foreground">
        {JSON.stringify(status.detail || status, null, 2)}
      </pre>
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
  const fieldLabel = "grid gap-1 text-xs font-medium text-muted-foreground"

  const cwdRequired =
    (state.cwd_required_flavors || ["cc", "codex"]).includes(form.flavor) ||
    (form.with_pty && (state.cwd_required_with_pty_flavors || ["echo"]).includes(form.flavor))

  // Light client validation; the authoritative parse runs server-side on submit.
  const capTokens = form.caps.split(",").map((c) => c.trim()).filter(Boolean)
  const capsInvalid = capTokens.some((t) => !/^[a-z_]+\.[a-z_]+$/.test(t))

  return (
    <section className={surfaceClass} data-world-component="agent_new_form" aria-labelledby="agent-new-title">
      <SectionHeader eyebrow="Provision" title="New agent" />
      {state.create_error && (
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
          {state.create_error}
        </p>
      )}
      <form
        id="world-agent-new-form"
        className="grid gap-3 sm:grid-cols-2"
        onSubmit={(event) => {
          event.preventDefault()
          onCreateAgent?.(form)
        }}
      >
        <label className={fieldLabel}>
          <span>Flavor</span>
          <Select value={form.flavor} onChange={(event) => setForm({...form, flavor: event.target.value})}>
            {(state.flavors || [form.flavor]).map((flavor) => (
              <option key={flavor} value={flavor}>{flavor}</option>
            ))}
          </Select>
        </label>
        <label className={fieldLabel}>
          <span>Name *</span>
          <Input value={form.name} onChange={(event) => setForm({...form, name: event.target.value})} placeholder="storefront-greeter" />
        </label>
        <label className={fieldLabel}>
          <span>project_cwd {cwdRequired ? "*" : "(optional for this flavor)"}</span>
          <Input value={form.cwd} onChange={(event) => setForm({...form, cwd: event.target.value})} placeholder="/srv/acme/storefront" />
        </label>
        <label className={fieldLabel}>
          <span>Requested caps</span>
          <Input value={form.caps} onChange={(event) => setForm({...form, caps: event.target.value})} placeholder="chat.send, workspace.read" />
          <span className={capsInvalid ? "text-xs text-destructive" : "text-xs text-muted-foreground"}>
            {capsInvalid ? "格式应为 behavior.action（逗号分隔）" : "请求 → 系统按 CapBAC 授予（详情页显示 granted）"}
          </span>
        </label>
        <label className="flex items-center gap-2 text-sm text-foreground">
          <input type="checkbox" checked={form.with_pty} onChange={(event) => setForm({...form, with_pty: event.target.checked})} />
          <span>With PTY</span>
        </label>
        <div className="flex items-center justify-between gap-3 sm:col-span-2">
          <code className={codeClass}>{preview}</code>
          <Button type="submit" disabled={!form.name || (cwdRequired && !form.cwd) || capsInvalid}>
            <Plus aria-hidden="true" />
            Create
          </Button>
        </div>
      </form>
      <ContractCoverage />
    </section>
  )
}

function ContractCoverage() {
  const pending: Array<[string, string]> = [
    ["soul · skills · tools · lifecycle", "Pending backend approval"],
    ["executor extras (settings/mcp/model/provider)", "Pending backend approval"],
    ["fork (parent template)", "Deferred"],
  ]
  return (
    <div className="space-y-2 border-t border-border pt-3">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Contract coverage (read-only)</p>
      <ul className="space-y-1">
        {pending.map(([field, badge]) => (
          <li className="flex items-center justify-between gap-3 text-sm text-muted-foreground" key={field}>
            <span>{field}</span>
            <span className="rounded-full border border-border bg-muted/50 px-2 py-0.5 text-xs">{badge}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

function AgentApiKeys({state}: {state: IdentitiesState}) {
  const keys = Array.isArray(state.api_keys) ? state.api_keys : []
  const error = !Array.isArray(state.api_keys) ? state.api_keys?.error : undefined
  const unsupported = !Array.isArray(state.api_keys) ? state.api_keys?.unsupported : false

  if (unsupported) {
    return (
      <section className={surfaceClass} data-world-component="agent_api_keys" aria-labelledby="api-keys-title">
        <SectionHeader eyebrow="Secrets" title="Agent API keys" />
        <code className={uriClass}>{state.agent_uri}</code>
        <EmptyState label="This agent flavor does not support API keys." />
      </section>
    )
  }

  return (
    <section className={surfaceClass} data-world-component="agent_api_keys" aria-labelledby="api-keys-title">
      <SectionHeader eyebrow="Secrets" title="Agent API keys" />
      <code className={uriClass}>{state.agent_uri}</code>
      {error && <p className="text-sm text-destructive">{error}</p>}
      <div className={tableWrapClass}>
        <table className={tableClass} id="world-api-keys-table">
          <thead className={theadClass}>
            <tr>
              <th className={thClass}>Provider</th>
              <th className={thClass}>Masked</th>
            </tr>
          </thead>
          <tbody className={tbodyClass}>
            {keys.map((key) => (
              <tr key={key.provider} className={rowClass}>
                <td className={tdClass}>{key.provider}</td>
                <td className={tdClass}>
                  <code className={codeClass}>{key.masked}</code>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {keys.length === 0 && !error && <EmptyState label="No stored keys." />}
      </div>
    </section>
  )
}

function AgentExtensions({state}: {state: IdentitiesState}) {
  const extensions = state.extensions || []

  return (
    <section className={surfaceClass} data-world-component="agent_extensions" aria-labelledby="agent-extensions-title">
      <SectionHeader eyebrow="Extensions" title="Agent extensions" />
      <code className={uriClass}>{state.agent_uri}</code>
      {state.error && <p className="text-sm text-destructive">{state.error}</p>}
      {state.notice && <p className="text-sm text-muted-foreground">{state.notice}</p>}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {extensions.map((extension) => (
          <article className="space-y-1 rounded-md border border-border bg-background p-3" key={extension.id || extension.name}>
            <strong className="text-foreground">{extension.name || extension.id}</strong>
            <p className="text-sm text-muted-foreground">{extension.description || "No description."}</p>
            <span className="text-xs text-muted-foreground">{extension.enabled ? "enabled" : "disabled"}</span>
          </article>
        ))}
        {extensions.length === 0 && <EmptyState label="No extensions available." />}
      </div>
    </section>
  )
}

function SectionHeader({eyebrow, title, actions}: {eyebrow: string; title: string; actions?: React.ReactNode}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div>
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{eyebrow}</p>
        <h2 className="text-lg font-semibold text-foreground">{title}</h2>
      </div>
      {actions}
    </div>
  )
}

function IdentityCard({row}: {row: IdentityRow}) {
  return (
    <article className="space-y-2 rounded-md border border-border bg-background p-3">
      <div className="flex items-center gap-2 text-muted-foreground">
        {row.kind === "agent" ? <UsersRound aria-hidden="true" className="h-4 w-4" /> : <UserRound aria-hidden="true" className="h-4 w-4" />}
        <div>
          <strong className="block text-foreground">{row.display_name || row.name || row.uri}</strong>
          <code className={codeClass}>{row.uri}</code>
        </div>
      </div>
      <p className="text-sm text-muted-foreground">{row.kind === "agent" ? `Agent ${row.flavor || "unknown"}` : "User"}</p>
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
  const filters: Array<[string, string]> = [
    ["All", "/identities"],
    ["Users", "/identities/users"],
    ["Agents", "/identities/agents"],
    ...flavors.map((flavor): [string, string] => [`agent:${flavor}`, `/identities?filter=${encodeURIComponent(`agent:${flavor}`)}`]),
  ]

  return (
    <div className="flex flex-wrap items-center gap-2">
      {filters.map(([label, href]) => (
        <a
          className={
            activeMatches(active, label)
              ? "rounded-md bg-accent px-3 py-1 text-xs font-medium text-accent-foreground"
              : "rounded-md border border-border px-3 py-1 text-xs font-medium text-muted-foreground hover:bg-muted hover:text-foreground"
          }
          href={href}
          key={href}
        >
          {label}
        </a>
      ))}
    </div>
  )
}

function InlineLinks({links}: {links: Array<[string, string | null | undefined]>}) {
  return (
    <div className="flex flex-wrap gap-3 text-xs">
      {links
        .filter(([, href]) => Boolean(href))
        .map(([label, href]) => (
          <a className="text-primary hover:underline" href={href || "#"} key={label}>
            {label}
          </a>
        ))}
    </div>
  )
}

function activeMatches(active: string, label: string) {
  if (label === "All") return active === "all"
  if (label === "Users") return active === "users"
  if (label === "Agents") return active === "agents"
  return active === label
}

function previewAgentUri(workspaceUri: string | null | undefined, name: string) {
  const workspace = workspaceUri?.replace("workspace://", "") || "system"
  return `entity://${workspace}/agent/${name}`
}

function formatList(values: string[] | undefined) {
  if (!values || values.length === 0) return ""
  return `via ${values.join(", ")}`
}
