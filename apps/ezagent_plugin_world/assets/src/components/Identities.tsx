import React from "react"
import {Plus, UserRound, UsersRound} from "lucide-react"

import {Button, EmptyState, Input, Select} from "./ui/primitives"

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
  config_path?: string | null
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

type CascadeLayer = {
  body?: Record<string, unknown> | null
  config_id?: string | null
}

type CascadeKeyEntry = {
  key: string
  effective_body: Record<string, unknown>
  editable: boolean
  editable_layer: string
  layers: {
    workspace?: CascadeLayer | null
    user?: CascadeLayer | null
    session?: CascadeLayer | null
  }
}

type CascadeState = {
  agent_uri: string
  workspace_uri: string
  default_key: string
  layer_order: string[]
  keys: CascadeKeyEntry[]
}

type ConfigFieldRow = {
  key: string
  value?: unknown
  source?: string
}

type NotWiredRow = {
  key: string
  reason: string
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
  granted_caps?: CapRow[] | {error?: string}
  project_cwd?: string | null
  config_dir?: string | null
  config_path?: string | null
  source_template?: string | null
  config_fields?: ConfigFieldRow[]
  config_schema?: ConfigSchemaField[]
  config_schemas?: Record<string, ConfigSchemaField[]>
  not_wired?: NotWiredRow[]
  flavor?: string
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
  action_error?: string
  cascade?: CascadeState
  config_error?: string
}

type Props = {
  state: IdentitiesState
  onCreateAgent?: (payload: Record<string, unknown>) => void
  onDeleteAgent?: (agentUri: string) => void
  onConfigUpdate?: (agentUri: string, key: string, patch: Record<string, unknown>) => void
  onConfigDeletePath?: (agentUri: string, key: string, path: string[]) => void
  onPutApiKey?: (payload: {agent_uri: string; provider: string; key: string}) => void
}

// Shared shadcn token classes (consistent with the admin/sessions clusters).
const surfaceClass = "space-y-4 rounded-lg border border-border bg-card p-5 text-card-foreground"
const fieldLabel = "grid gap-1 text-xs font-medium text-muted-foreground"
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

export function IdentitiesSurface({state, onCreateAgent, onDeleteAgent, onConfigUpdate, onConfigDeletePath, onPutApiKey}: Props) {
  if (state.component === "users_table") return <UsersTable state={state} />
  if (state.component === "agents_table") return <AgentsTable state={state} />
  if (state.component === "entity_caps") return <EntityCaps state={state} />
  if (state.component === "agent_detail") return <AgentDetail state={state} onDeleteAgent={onDeleteAgent} />
  if (state.component === "agent_new_form") return <AgentNewForm state={state} onCreateAgent={onCreateAgent} />
  if (state.component === "agent_api_keys") return <AgentApiKeys state={state} onPutApiKey={onPutApiKey} />
  if (state.component === "agent_extensions") return <AgentExtensions state={state} />
  if (state.component === "agent_config") return <AgentConfigEditor state={state} onConfigUpdate={onConfigUpdate} onConfigDeletePath={onConfigDeletePath} />
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
      {state.action_error && (
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
          {state.action_error}
        </p>
      )}
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
                      ["Config", agent.config_path],
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

function AgentDetail({state, onDeleteAgent}: {state: IdentitiesState; onDeleteAgent?: (agentUri: string) => void}) {
  const [confirming, setConfirming] = React.useState(false)
  const status = (state.agent_status || {}) as Record<string, unknown>
  const grantedCaps = Array.isArray(state.granted_caps) ? state.granted_caps : []
  const rows: Array<[string, string]> = [
    ["Phase", String(status.phase || "unknown")],
    ["Flavor", String(state.flavor || status.flavor || "unknown")],
    ["project_cwd", String(state.project_cwd || "—")],
    ["config_dir", String(state.config_dir || "—")],
    ["Template", state.source_template ? `per-agent (${state.source_template})` : "direct-spawn (no template)"],
    ["Bridge", state.bridge ? "connected" : "not connected"],
  ]

  const configFields = state.config_fields || []
  const notWired = state.not_wired || []

  return (
    <section className={surfaceClass} data-world-component="agent_detail" aria-labelledby="agent-detail-title">
      <SectionHeader eyebrow="Agent" title="Agent detail" />
      <code className={uriClass}>{state.agent_uri}</code>
      <dl className="grid grid-cols-1 gap-2 sm:grid-cols-2">
        {rows.map(([label, value]) => (
          <div className="flex justify-between gap-3 rounded-md border border-border bg-background px-3 py-2" key={label}>
            <dt className="text-xs font-medium text-muted-foreground">{label}</dt>
            <dd className="text-sm text-foreground">{value}</dd>
          </div>
        ))}
      </dl>

      {/* M1: Per-flavor config fields from template data + config cascade */}
      {configFields.length > 0 && (
        <div>
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground mb-2">
            Configuration (按 flavor 展示)
          </p>
          <dl className="grid grid-cols-1 gap-2 sm:grid-cols-2">
            {configFields.map((f) => (
              <div className="flex justify-between gap-3 rounded-md border border-border bg-background px-3 py-2" key={f.key}>
                <dt className="text-xs font-medium text-muted-foreground">
                  {f.key}
                  <span className="ml-1 text-[10px] text-muted-foreground/60">({f.source})</span>
                </dt>
                <dd className="text-sm text-foreground truncate max-w-[200px]" title={f.value ?? ""}>
                  {formatConfigValue(f.value)}
                </dd>
              </div>
            ))}
          </dl>
        </div>
      )}

      {/* M1: Not-wired annotations — per-field, precise labels */}
      {notWired.length > 0 && (
        <div>
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground mb-2">
            还没接线
          </p>
          <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
            {notWired.map((nw) => (
              <div className="flex items-center gap-2 rounded-md border border-dashed border-muted-foreground/30 bg-muted/20 px-3 py-1.5" key={nw.key}>
                <span className="font-mono text-xs text-muted-foreground">{nw.key}</span>
                <span className="text-xs text-muted-foreground/70">{nw.reason}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      <div>
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Granted caps (CapBAC)</p>
        <div className="flex flex-wrap gap-2 pt-1">
          {grantedCaps.map((c, i) => (
            <span className="rounded-md border border-border bg-muted/50 px-2 py-0.5 font-mono text-xs" key={i}>
              {[c.behavior, c.action].filter(Boolean).join(".")}
            </span>
          ))}
          {grantedCaps.length === 0 && <span className="text-sm text-muted-foreground">none</span>}
        </div>
      </div>
      <div className="flex flex-wrap gap-3">
        <InlineLinks links={[["Config", state.config_path]]} />
      </div>
      <div className="border-t border-border pt-3">
        {!confirming && (
          <Button variant="ghost" className="text-destructive hover:text-destructive" onClick={() => setConfirming(true)}>
            Delete agent
          </Button>
        )}
        {confirming && (
          <div className="flex items-center gap-2">
            <span className="text-sm text-destructive">确认删除该 agent？此操作不可撤销。</span>
            <Button
              onClick={() => {
                if (state.agent_uri) onDeleteAgent?.(state.agent_uri)
              }}
            >
              确认删除
            </Button>
            <Button variant="ghost" onClick={() => setConfirming(false)}>取消</Button>
          </div>
        )}
      </div>
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
    configFields: {} as Record<string, string>,
  })
  const preview = form.name ? previewAgentUri(state.workspace_uri, form.name) : state.preview_uri || "<agent-uri>"

  const cwdRequired =
    (state.cwd_required_flavors || ["cc", "codex"]).includes(form.flavor) ||
    (form.with_pty && (state.cwd_required_with_pty_flavors || ["echo"]).includes(form.flavor))

  // M4: flavor-specific schema for dynamic create fields
  const flavorSchema = (state.config_schemas || {})[form.flavor] || []

  // Light client validation; the authoritative parse runs server-side on submit.
  const capTokens = form.caps.split(",").map((c) => c.trim()).filter(Boolean)
  const capsInvalid = capTokens.some((t) => !/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/.test(t))

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault()
    // M4: include flavor-specific config fields in the payload
    const configFields = form.configFields || {}
    const filteredFields: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(configFields)) {
      if (v != null && v !== "") filteredFields[k] = v
    }
    onCreateAgent?.({...form, config_fields: filteredFields})
  }

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
        onSubmit={handleSubmit}
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

        {/* M4: Flavor-specific config fields from schema */}
        {flavorSchema.filter(f => f.key !== "soul_md").length > 0 && (
          <div className="sm:col-span-2 border-t border-border pt-3">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground mb-2">
              {form.flavor} configuration
            </p>
            <div className="grid gap-2 sm:grid-cols-2">
              {flavorSchema.filter(f => f.key !== "soul_md").map((f) => (
                <label className={fieldLabel} key={f.key}>
                  <span className="font-mono text-xs">
                    {f.label || f.key}
                    {f.help && <span className="text-[10px] text-muted-foreground ml-1">({f.help})</span>}
                  </span>
                  {f.type === "enum" && f.options ? (
                    <Select
                      value={form.configFields[f.key] || ""}
                      onChange={(e) => setForm({...form, configFields: {...form.configFields, [f.key]: e.target.value}})}
                    >
                      <option value="">{f.default ? `默认: ${f.default}` : "—"}</option>
                      {f.options.map((opt) => (
                        <option key={opt} value={opt}>{opt}</option>
                      ))}
                    </Select>
                  ) : f.type === "text" ? (
                    <textarea
                      className="w-full rounded-md border border-border bg-background px-2 py-1.5 font-mono text-xs text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                      rows={2}
                      value={form.configFields[f.key] || ""}
                      onChange={(e) => setForm({...form, configFields: {...form.configFields, [f.key]: e.target.value}})}
                      placeholder={String(f.default || "")}
                    />
                  ) : f.type === "boolean" ? (
                    <Select
                      value={form.configFields[f.key] || ""}
                      onChange={(e) => setForm({...form, configFields: {...form.configFields, [f.key]: e.target.value}})}
                    >
                      <option value="">—</option>
                      <option value="true">true</option>
                      <option value="false">false</option>
                    </Select>
                  ) : (
                    <Input
                      value={form.configFields[f.key] || ""}
                      onChange={(e) => setForm({...form, configFields: {...form.configFields, [f.key]: e.target.value}})}
                      className="font-mono text-xs"
                      placeholder={String(f.default || "")}
                    />
                  )}
                </label>
              ))}
            </div>
          </div>
        )}

        <label className={fieldLabel}>
          <span>Requested caps</span>
          <Input value={form.caps} onChange={(event) => setForm({...form, caps: event.target.value})} placeholder="chat.send, workspace.read" />
          <span className={capsInvalid ? "text-xs text-destructive" : "text-xs text-muted-foreground"}>
            {capsInvalid
              ? "格式：kind.behavior（逗号分隔，如 chat.send）"
              : "请求 kind.behavior（action 默认 any）→ 系统按 CapBAC 授予（详情页显示 granted）"}
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

type AgentConfigEditorProps = {
  state: IdentitiesState
  onConfigUpdate?: (agentUri: string, key: string, patch: Record<string, unknown>) => void
  onConfigDeletePath?: (agentUri: string, key: string, path: string[]) => void
}

function AgentConfigEditor({state, onConfigUpdate, onConfigDeletePath}: AgentConfigEditorProps) {
  const agentUri = state.agent_uri || ""

  if (state.config_error) {
    return (
      <section className={surfaceClass} data-world-component="agent_config" aria-labelledby="agent-config-title">
        <SectionHeader eyebrow="Agent" title="Agent config" />
        <code className={uriClass}>{agentUri}</code>
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
          {state.config_error}
        </p>
      </section>
    )
  }

  const cascade = state.cascade
  if (!cascade) {
    return (
      <section className={surfaceClass} data-world-component="agent_config" aria-labelledby="agent-config-title">
        <SectionHeader eyebrow="Agent" title="Agent config" />
        <code className={uriClass}>{agentUri}</code>
        <p className="text-sm text-muted-foreground">Loading config…</p>
      </section>
    )
  }

  return (
    <section className={surfaceClass} data-world-component="agent_config" aria-labelledby="agent-config-title">
      <SectionHeader eyebrow="Agent" title="Agent config" />
      <code className={uriClass}>{agentUri}</code>
      <div className="space-y-6">
        {(cascade.keys ?? []).map((keyEntry) => (
          <AgentConfigKeySection
            key={keyEntry.key}
            agentUri={agentUri}
            keyEntry={keyEntry}
            schema={state.config_schema}
            onConfigUpdate={onConfigUpdate}
            onConfigDeletePath={onConfigDeletePath}
          />
        ))}
        {(cascade.keys ?? []).length === 0 && (
          <p className="text-sm text-muted-foreground">No config keys found.</p>
        )}
      </div>
    </section>
  )
}

type ConfigSchemaField = {
  key: string
  type: string
  label?: string
  options?: string[]
  default?: unknown
  required?: boolean
  help?: string
}

type AgentConfigKeySectionProps = {
  agentUri: string
  keyEntry: CascadeKeyEntry
  schema?: ConfigSchemaField[]
  onConfigUpdate?: (agentUri: string, key: string, patch: Record<string, unknown>) => void
  onConfigDeletePath?: (agentUri: string, key: string, path: string[]) => void
}

function AgentConfigKeySection({agentUri, keyEntry, schema, onConfigUpdate, onConfigDeletePath}: AgentConfigKeySectionProps) {
  // Initialize editable fields from the effective_body
  const [editedFields, setEditedFields] = React.useState<Record<string, unknown>>(() => ({...keyEntry.effective_body}))
  const [newFieldName, setNewFieldName] = React.useState("")
  const [newFieldValue, setNewFieldValue] = React.useState("")
  const [dirty, setDirty] = React.useState(false)

  // Fix #1: re-sync to the durable server value whenever the server re-pushes a
  // fresh cascade (e.g. after Save or delete).  useState only runs the initializer
  // once — this effect keeps the editor honest across prop updates.
  React.useEffect(() => {
    setEditedFields({...keyEntry.effective_body})
    setDirty(false)
  }, [keyEntry.effective_body])

  const handleFieldChange = (field: string, value: string) => {
    setEditedFields((prev) => ({...prev, [field]: value}))
    setDirty(true)
  }

  const handleSave = () => {
    onConfigUpdate?.(agentUri, keyEntry.key, editedFields)
    setDirty(false)
  }

  const handleDeleteField = (field: string) => {
    // Fix #2: optimistically drop the field so it doesn't bounce back
    // visually during the server round-trip.  The useEffect above will
    // re-sync the authoritative value once the server re-pushes.
    setEditedFields((prev) => {
      const next = {...prev}
      delete next[field]
      return next
    })
    onConfigDeletePath?.(agentUri, keyEntry.key, [field])
  }

  const handleAddField = () => {
    if (!newFieldName.trim()) return
    setEditedFields((prev) => ({...prev, [newFieldName.trim()]: newFieldValue}))
    setNewFieldName("")
    setNewFieldValue("")
    setDirty(true)
  }

  // Read-only context: workspace and session layer values
  const workspaceBody = keyEntry.layers.workspace?.body
  const sessionBody = keyEntry.layers.session?.body

  return (
    <div className="space-y-3 rounded-md border border-border bg-background p-4">
      <div className="flex items-center justify-between gap-3">
        <h3 className="font-mono text-sm font-semibold text-foreground">{keyEntry.key}</h3>
        <span className="rounded-full border border-border bg-muted/50 px-2 py-0.5 text-xs text-muted-foreground">
          user layer editable
        </span>
      </div>

      {/* Read-only context: workspace layer */}
      {workspaceBody && Object.keys(workspaceBody).length > 0 && (
        <div className="space-y-1">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Workspace layer (read-only)</p>
          <div className="grid gap-1 rounded-md bg-muted/30 p-2">
            {Object.entries(workspaceBody).map(([field, val]) => (
              <div className="flex items-center gap-2 text-xs" key={field}>
                <span className="w-32 shrink-0 font-mono text-muted-foreground">{field}</span>
                <span className="font-mono text-foreground">{String(val ?? "")}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Read-only context: session layer */}
      {sessionBody && Object.keys(sessionBody).length > 0 && (
        <div className="space-y-1">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Session layer (read-only)</p>
          <div className="grid gap-1 rounded-md bg-muted/30 p-2">
            {Object.entries(sessionBody).map(([field, val]) => (
              <div className="flex items-center gap-2 text-xs" key={field}>
                <span className="w-32 shrink-0 font-mono text-muted-foreground">{field}</span>
                <span className="font-mono text-foreground">{String(val ?? "")}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Editable user layer fields */}
      <div className="space-y-2">
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">User layer (editable)</p>
        {Object.entries(editedFields).map(([field, val]) => {
          const schemaField = (schema || []).find(s => s.key === field)
          return (
          <div className="flex items-start gap-2" key={field}>
            <div className="flex-1">
              <label className={fieldLabel}>
                <span className="font-mono">{schemaField?.label || field}</span>
                {schemaField?.help && <span className="text-[10px] text-muted-foreground ml-1">({schemaField.help})</span>}
                <ConfigFieldWidget
                  field={field}
                  value={val}
                  schemaType={schemaField?.type}
                  options={schemaField?.options}
                  onChange={(v) => handleFieldChange(field, v)}
                />
              </label>
            </div>
            <button
              type="button"
              className="mt-5 flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-border text-muted-foreground transition hover:border-destructive hover:text-destructive"
              title={`Remove field ${field}`}
              onClick={() => handleDeleteField(field)}
              aria-label={`Remove field ${field}`}
            >
              ×
            </button>
          </div>
        )})}

        {/* Add new field row */}
        <div className="flex items-end gap-2 border-t border-border pt-2">
          <label className={`${fieldLabel} flex-1`}>
            <span>New field name</span>
            <Input
              value={newFieldName}
              onChange={(e) => setNewFieldName(e.target.value)}
              placeholder="field_name"
              className="font-mono"
            />
          </label>
          <label className={`${fieldLabel} flex-1`}>
            <span>Value</span>
            <Input
              value={newFieldValue}
              onChange={(e) => setNewFieldValue(e.target.value)}
              placeholder="value"
              className="font-mono"
            />
          </label>
          <Button
            type="button"
            variant="secondary"
            onClick={handleAddField}
            disabled={!newFieldName.trim()}
          >
            Add
          </Button>
        </div>
      </div>

      <div className="flex justify-end border-t border-border pt-2">
        <Button
          type="button"
          onClick={handleSave}
          disabled={!dirty}
        >
          Save
        </Button>
      </div>
    </div>
  )
}

// ── M3: Schema-aware config field widget ────────────────────────────

type ConfigFieldWidgetProps = {
  field: string
  value: unknown
  schemaType?: string
  options?: string[]
  onChange: (value: string) => void
}

function ConfigFieldWidget({field, value, schemaType, options, onChange}: ConfigFieldWidgetProps) {
  const strValue = String(value ?? "")

  switch (schemaType) {
    case "text":
      return (
        <textarea
          className="w-full rounded-md border border-border bg-background px-2 py-1.5 font-mono text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
          rows={4}
          value={strValue}
          onChange={(e) => onChange(e.target.value)}
        />
      )
    case "enum":
    case "list":
      return options && options.length > 0 ? (
        <Select value={strValue} onChange={(e) => onChange(e.target.value)}>
          <option value="">—</option>
          {options.map((opt) => (
            <option key={opt} value={opt}>{opt}</option>
          ))}
        </Select>
      ) : (
        <Input
          value={strValue}
          onChange={(e) => onChange(e.target.value)}
          className="font-mono"
          placeholder={schemaType === "list" ? "逗号分隔" : ""}
        />
      )
    case "json":
      return (
        <textarea
          className="w-full rounded-md border border-border bg-background px-2 py-1.5 font-mono text-xs text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-1 focus:ring-ring"
          rows={3}
          value={strValue}
          onChange={(e) => onChange(e.target.value)}
          placeholder='{"key": "value"}'
        />
      )
    case "boolean":
      return (
        <Select value={strValue} onChange={(e) => onChange(e.target.value)}>
          <option value="">—</option>
          <option value="true">true</option>
          <option value="false">false</option>
        </Select>
      )
    case "integer":
      return (
        <Input
          type="number"
          value={strValue}
          onChange={(e) => onChange(e.target.value)}
          className="font-mono"
        />
      )
    case "secret":
      return (
        <Input
          type="password"
          value={strValue}
          onChange={(e) => onChange(e.target.value)}
          className="font-mono"
          autoComplete="off"
        />
      )
    default:
      // string or unknown type — fallback to generic Input
      return (
        <Input
          value={strValue}
          onChange={(e) => onChange(e.target.value)}
          className="font-mono"
        />
      )
  }
}

function AgentApiKeys({
  state,
  onPutApiKey,
}: {
  state: IdentitiesState
  onPutApiKey?: (payload: {agent_uri: string; provider: string; key: string}) => void
}) {
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
      {state.can_edit && state.agent_uri && (
        <AddApiKeyForm agentUri={state.agent_uri} onPutApiKey={onPutApiKey} />
      )}
    </section>
  )
}

// The write half of the API-keys page (F10). Only rendered when `can_edit` —
// the same data-owner/admin affordance the server gate enforces — so a viewer
// without edit rights never sees it. Dispatches `agent.api_key.put` over the LV
// socket (NOT a native form POST: the world surface is a LiveView page whose
// client JS swallows native submits from the React island); the masked table
// refreshes from the server's re-pushed world:state. The key is a secret, so
// the input is masked and cleared on submit.
function AddApiKeyForm({
  agentUri,
  onPutApiKey,
}: {
  agentUri: string
  onPutApiKey?: (payload: {agent_uri: string; provider: string; key: string}) => void
}) {
  const [form, setForm] = React.useState({provider: "", key: ""})
  const fieldLabel = "grid gap-1 text-xs font-medium text-muted-foreground"
  const canSubmit = form.provider.trim() !== "" && form.key.trim() !== ""

  return (
    <form
      id="world-api-key-form"
      className="grid gap-3 border-t border-border pt-4 sm:grid-cols-2"
      onSubmit={(event) => {
        event.preventDefault()
        if (!canSubmit) return
        onPutApiKey?.({agent_uri: agentUri, provider: form.provider.trim(), key: form.key.trim()})
        setForm({provider: "", key: ""})
      }}
    >
      <label className={fieldLabel}>
        <span>Provider *</span>
        <Input
          value={form.provider}
          onChange={(event) => setForm({...form, provider: event.target.value})}
          placeholder="deepseek"
          autoComplete="off"
        />
      </label>
      <label className={fieldLabel}>
        <span>API key *</span>
        <Input
          type="password"
          value={form.key}
          onChange={(event) => setForm({...form, key: event.target.value})}
          placeholder="sk-…"
          autoComplete="off"
        />
      </label>
      <div className="flex items-center justify-end sm:col-span-2">
        <Button type="submit" disabled={!canSubmit}>
          <Plus aria-hidden="true" />
          Save key
        </Button>
      </div>
    </form>
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

function formatConfigValue(value: unknown): string {
  if (value == null) return "—"
  if (typeof value === "boolean") return value ? "true" : "false"
  if (typeof value === "number") return String(value)
  if (typeof value === "string") {
    if (value.length > 80) return value.slice(0, 80) + "…"
    return value
  }
  // objects, arrays — JSON compact
  try { return JSON.stringify(value) } catch { return String(value) }
}
