import React from "react"
import {Ban, CheckCircle2, FolderLock, HardDrive, KeyRound, Loader2, Plus, RotateCcw, Save, TerminalSquare, Trash2, UserRound, UsersRound} from "lucide-react"

import {Button, EmptyState, Input, Select} from "./ui/primitives"

// #160 — normalized credential status pushed as route state (owner + ws-admin
// only; null/absent when the caller may not manage the agent, so the badge hides).
type CredentialStatus = {
  status?: string
  flavor?: string | null
  detail?: string | null
  expires_at?: number | null
  checked_at?: string | null
}

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
  credential_status?: CredentialStatus | null
}

type UserRow = {
  uri: string
  display_name?: string
  email?: string | null
  has_password?: boolean
  confirmed?: boolean
  email_verified?: boolean
  disabled?: boolean
  disabled_at?: string | null
  disabled_by?: string | null
  disabled_reason?: string | null
  cap_count?: number
  online?: boolean
  transports?: string[]
  system_member?: boolean
  caps_path?: string | null
  detail_path?: string | null
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
  user_uri?: string | null
  agents?: IdentityRow[]
  api_keys?: ApiKeyRow[] | {error?: string; unsupported?: boolean}
  bridge?: Record<string, unknown> | null
  can_edit?: boolean
  caps?: CapRow[] | {error?: string}
  granted_caps?: CapRow[] | {error?: string}
  project_cwd?: string | null
  config_dir?: string | null
  config_path?: string | null
  credential_status?: CredentialStatus | null
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
  caps_path?: string | null
  extensions?: ExtensionRow[]
  filter?: string
  flavors?: string[]
  notice?: string
  path?: string
  preview_uri?: string
  title?: string
  users?: UserRow[]
  user_not_found?: boolean
  user_unauthorized?: boolean
  // Server-gated (read-plane PR-4 re-review): true only when the caller
  // may see the user detail's account/security metadata (self or
  // operator). Sensitive fields arrive null otherwise — render the
  // directory-level view, never a negated value.
  can_view_metadata?: boolean
  display_name?: string | null
  email?: string | null
  has_password?: boolean
  confirmed?: boolean
  email_verified?: boolean
  disabled?: boolean
  disabled_at?: string | null
  disabled_by?: string | null
  disabled_reason?: string | null
  cap_count?: number
  workspace_uri?: string | null
  allowed_project_cwd_roots?: string[]
  cwd_required_flavors?: string[]
  cwd_required_with_pty_flavors?: string[]
  script_required_flavors?: string[]
  create_error?: string | null
  action_error?: string
  agent_not_found?: boolean
  cascade?: CascadeState
  config_error?: string
}

type Props = {
  state: IdentitiesState
  onCreateAgent?: (payload: Record<string, unknown>) => void
  onCreateUser?: (payload: Record<string, unknown>) => void
  onSaveUserProfile?: (payload: {user_uri: string; display_name: string; email: string}) => void
  onSetUserPassword?: (payload: {user_uri: string; password: string}) => void
  onDisableUser?: (payload: {user_uri: string; reason: string}) => void
  onEnableUser?: (payload: {user_uri: string}) => void
  onDeleteAgent?: (agentUri: string) => void
  onConfigUpdate?: (agentUri: string, key: string, patch: Record<string, unknown>) => void
  onConfigDeletePath?: (agentUri: string, key: string, path: string[]) => void
  onPutApiKey?: (payload: {agent_uri: string; provider: string; key: string}) => void
  onDeleteApiKey?: (payload: {agent_uri: string; provider: string}) => void
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
const secondaryActionLinkClass =
  "inline-flex items-center gap-1.5 rounded-md border border-border bg-background px-3 py-1.5 text-sm font-medium text-foreground transition hover:bg-muted"
const agentShellClass =
  "grid h-full min-h-0 overflow-hidden border-y border-border bg-background text-foreground lg:grid-cols-[276px_minmax(520px,1fr)]"
const agentPanelClass = "min-h-0 overflow-y-auto bg-background p-4"
const agentTabs = ["Overview", "Config", "Keys", "Caps", "Extensions"] as const
const defaultAgentFlavors = ["cc", "cc-headless", "codex", "codex-remote", "py", "curl", "native"]
const defaultCreateSchema: Record<string, ConfigSchemaField[]> = {
  cc: [
    {key: "model", type: "string", label: "model", placeholder: "claude-sonnet-4-6", help: "Example: claude-sonnet-4-6; leave blank for Claude Code default"},
    {key: "effort", type: "enum", label: "effort", options: ["default", "low", "medium", "high"]},
    {key: "permission_mode", type: "enum", label: "permission_mode", options: ["default", "acceptEdits", "bypassPermissions", "plan"]},
    {key: "allowed_tools", type: "string", label: "tools", help: "comma-separated list"},
  ],
  "cc-headless": [
    {key: "model", type: "string", label: "model", placeholder: "claude-sonnet-4-6", help: "Example: claude-sonnet-4-6; leave blank for Claude Code default"},
    {key: "effort", type: "enum", label: "effort", options: ["default", "low", "medium", "high"]},
    {key: "permission_mode", type: "enum", label: "permission_mode", options: ["default", "acceptEdits", "bypassPermissions", "plan"]},
    {key: "allowed_tools", type: "string", label: "tools", help: "comma-separated list"},
  ],
  codex: [
    {key: "model", type: "string", label: "model", placeholder: "leave blank for Codex default", help: "optional; accepts custom Codex model id"},
    {key: "approval_policy", type: "enum", label: "approval_policy", options: ["default", "on-request", "never"]},
    {key: "sandbox", type: "enum", label: "sandbox", options: ["default", "workspace-write", "read-only", "danger-full-access"]},
  ],
  "codex-remote": [
    {key: "model", type: "string", label: "model", placeholder: "leave blank for Codex default", help: "optional; accepts custom Codex model id"},
    {key: "approval_policy", type: "enum", label: "approval_policy", options: ["default", "on-request", "never"]},
    {key: "sandbox", type: "enum", label: "sandbox", options: ["default", "workspace-write", "read-only", "danger-full-access"]},
  ],
  py: [{key: "script", type: "text", label: "script", required: true}],
  curl: [
    {key: "provider", type: "string", label: "provider", required: true},
    {key: "api_url", type: "string", label: "api_url", required: true},
    {key: "model", type: "string", label: "model", required: true, placeholder: "deepseek-chat", help: "provider model id"},
  ],
  native: [{key: "role", type: "string", label: "role"}],
}

export function IdentitiesSurface({state, onCreateAgent, onCreateUser, onSaveUserProfile, onSetUserPassword, onDisableUser, onEnableUser, onDeleteAgent, onConfigUpdate, onConfigDeletePath, onPutApiKey, onDeleteApiKey}: Props) {
  if (state.component === "users_table") return <UsersTable state={state} />
  if (state.component === "user_new_form") return <UserNewForm state={state} onCreateUser={onCreateUser} />
  if (state.component === "user_detail") {
    return (
      <UserDetail
        state={state}
        onSaveUserProfile={onSaveUserProfile}
        onSetUserPassword={onSetUserPassword}
        onDisableUser={onDisableUser}
        onEnableUser={onEnableUser}
      />
    )
  }
  if (state.component === "agents_table") return <AgentsTable state={state} />
  if (state.component === "entity_caps") return <EntityCaps state={state} />
  if (state.component === "agent_detail") return <AgentDetail state={state} onDeleteAgent={onDeleteAgent} />
  if (state.component === "agent_new_form") return <AgentNewForm state={state} onCreateAgent={onCreateAgent} />
  if (state.component === "agent_api_keys") return <AgentApiKeys state={state} onPutApiKey={onPutApiKey} onDeleteApiKey={onDeleteApiKey} />
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
          <div className="flex flex-wrap items-center gap-2">
            <a className={actionLinkClass} href="/identities/users/new">
              <Plus aria-hidden="true" className="h-4 w-4" />
              New user
            </a>
            <a className={secondaryActionLinkClass} href="/identities/agents/new">
              <Plus aria-hidden="true" className="h-4 w-4" />
              New agent
            </a>
          </div>
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
      <SectionHeader
        eyebrow="Principals"
        title="Users"
        actions={
          <a className={actionLinkClass} href="/identities/users/new">
            <Plus aria-hidden="true" className="h-4 w-4" />
            New user
          </a>
        }
      />
      <div className={tableWrapClass}>
        <table className={tableClass} id="world-users-table">
          <thead className={theadClass}>
            <tr>
              <th className={thClass}>Name / URI</th>
              <th className={thClass}>Email</th>
              <th className={thClass}>Password</th>
              <th className={thClass}>Status</th>
              <th className={thClass}>Caps</th>
              <th className={thClass}>System</th>
              <th className={thClass}>Presence</th>
              <th className={thClass}>Actions</th>
            </tr>
          </thead>
          <tbody className={tbodyClass}>
            {users.map((user) => (
              <tr key={user.uri} className={rowClass}>
                <td className={tdClass}>
                  <strong className="block text-foreground">{user.display_name || user.uri}</strong>
                  <code className={codeClass}>{user.uri}</code>
                </td>
                <td className={tdClass}>{user.email || "—"}</td>
                <td className={tdClass}>{user.has_password ? "set" : "unset"}</td>
                <td className={tdClass}>
                  <StatusPill tone={user.disabled ? "danger" : "success"} label={user.disabled ? "disabled" : "active"} />
                </td>
                <td className={tdClass}>
                  <a className="text-primary hover:underline" href={user.caps_path || "#"}>
                    {user.cap_count || 0}
                  </a>
                </td>
                <td className={tdClass}>{user.system_member ? "system" : "workspace"}</td>
                <td className={tdClass}>{user.online ? `online ${formatList(user.transports)}` : "offline"}</td>
                <td className={tdClass}>
                  <InlineLinks links={[["Manage", user.detail_path], ["Caps", user.caps_path]]} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {users.length === 0 && <EmptyState label="No users." />}
      </div>
    </section>
  )
}

function UserNewForm({state, onCreateUser}: {state: IdentitiesState; onCreateUser?: (payload: Record<string, unknown>) => void}) {
  const [form, setForm] = React.useState({
    name: "",
    display_name: "",
    email: "",
    password: "",
  })

  const preview = form.name ? previewUserUri(state.workspace_uri, form.name) : state.preview_uri || "<user-uri>"

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault()
    onCreateUser?.(form)
  }

  return (
    <section className={surfaceClass} data-world-component="user_new_form" aria-labelledby="user-new-title">
      <SectionHeader eyebrow="Provision" title="New user" />
      {state.create_error && (
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
          {state.create_error}
        </p>
      )}
      <form id="world-user-new-form" className="grid gap-3 sm:grid-cols-2" onSubmit={handleSubmit}>
        <label className={fieldLabel}>
          <span>Name *</span>
          <Input value={form.name} onChange={(event) => setForm({...form, name: event.target.value})} placeholder="zhangning" />
        </label>
        <label className={fieldLabel}>
          <span>Display name</span>
          <Input value={form.display_name} onChange={(event) => setForm({...form, display_name: event.target.value})} placeholder="Zhang Ning" />
        </label>
        <label className={fieldLabel}>
          <span>Email</span>
          <Input type="email" value={form.email} onChange={(event) => setForm({...form, email: event.target.value})} placeholder="zhangning@example.com" />
        </label>
        <label className={fieldLabel}>
          <span>Password *</span>
          <Input type="password" value={form.password} onChange={(event) => setForm({...form, password: event.target.value})} />
        </label>
        <div className="flex items-center justify-between gap-3 sm:col-span-2">
          <code className={codeClass}>{preview}</code>
          <Button type="submit" disabled={!form.name.trim() || !form.password.trim()}>
            <Plus aria-hidden="true" />
            Create
          </Button>
        </div>
      </form>
    </section>
  )
}

function UserDetail({
  state,
  onSaveUserProfile,
  onSetUserPassword,
  onDisableUser,
  onEnableUser,
}: {
  state: IdentitiesState
  onSaveUserProfile?: (payload: {user_uri: string; display_name: string; email: string}) => void
  onSetUserPassword?: (payload: {user_uri: string; password: string}) => void
  onDisableUser?: (payload: {user_uri: string; reason: string}) => void
  onEnableUser?: (payload: {user_uri: string}) => void
}) {
  const userUri = state.user_uri || ""
  const [profile, setProfile] = React.useState({
    display_name: state.display_name || "",
    email: state.email || "",
  })
  const [password, setPassword] = React.useState("")
  const [reason, setReason] = React.useState(state.disabled_reason || "")

  React.useEffect(() => {
    setProfile({display_name: state.display_name || "", email: state.email || ""})
    setReason(state.disabled_reason || "")
  }, [state.display_name, state.email, state.disabled_reason])

  if (state.user_not_found) {
    return (
      <section className={surfaceClass} data-world-component="user_detail" aria-labelledby="user-detail-title">
        <SectionHeader eyebrow="User" title="User detail" />
        <code className={uriClass}>{state.user_uri}</code>
        <EmptyState label="该 user 不存在。" />
        <div>
          <a className="text-primary hover:underline" href="/identities/users">
            ← 返回 user 列表
          </a>
        </div>
      </section>
    )
  }

  // Read-plane PR-4 re-review: the deep-link read is authorized
  // server-side BEFORE existence is checked — a denied caller (e.g.
  // cross-tenant) gets this shell with no account data at all.
  if (state.user_unauthorized) {
    return (
      <section className={surfaceClass} data-world-component="user_detail" aria-labelledby="user-detail-title">
        <SectionHeader eyebrow="User" title="User detail" />
        <code className={uriClass}>{state.user_uri}</code>
        <EmptyState label="没有权限查看该 user。" />
        <div>
          <a className="text-primary hover:underline" href="/identities/users">
            ← 返回 user 列表
          </a>
        </div>
      </section>
    )
  }

  // An authorized NON-operator viewer (a workspace member opening
  // another member's deep-link) gets the directory-level view only —
  // the account/security rows and the management forms render ONLY
  // when the server confirms the caller may see the metadata (self or
  // operator). Sensitive fields arrive as null here; rendering
  // "unset"/"active" for them would assert a negation — itself a leak.
  if (state.can_view_metadata === false) {
    return (
      <section className={surfaceClass} data-world-component="user_detail" aria-labelledby="user-detail-title">
        <SectionHeader eyebrow="User" title="User detail" />
        <code className={uriClass}>{userUri}</code>
        <p className="text-sm text-foreground">{state.display_name}</p>
        <EmptyState label="账户信息仅本人或 operator 可见。" />
        <div>
          <a className="text-primary hover:underline" href="/identities/users">
            ← 返回 user 列表
          </a>
        </div>
      </section>
    )
  }

  return (
    <section className={surfaceClass} data-world-component="user_detail" aria-labelledby="user-detail-title">
      <SectionHeader eyebrow="User" title="User detail" />
      <code className={uriClass}>{userUri}</code>
      {state.action_error && (
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
          {state.action_error}
        </p>
      )}

      <dl className="grid grid-cols-1 gap-2 sm:grid-cols-2">
        <InfoRow label="Password" value={state.has_password ? "set" : "unset"} />
        <InfoRow label="Confirmed" value={state.confirmed ? "yes" : "no"} />
        <InfoRow label="Email verified" value={state.email_verified ? "yes" : "no"} />
        <InfoRow label="Status" value={state.disabled ? "disabled" : "active"} />
        {state.disabled_at && <InfoRow label="Disabled at" value={state.disabled_at} />}
        {state.disabled_by && <InfoRow label="Disabled by" value={state.disabled_by} />}
      </dl>

      <form
        id="world-user-profile-form"
        className="grid gap-3 rounded-md border border-border bg-background p-4 sm:grid-cols-2"
        onSubmit={(event) => {
          event.preventDefault()
          onSaveUserProfile?.({user_uri: userUri, ...profile})
        }}
      >
        <label className={fieldLabel}>
          <span>Display name</span>
          <Input value={profile.display_name} onChange={(event) => setProfile({...profile, display_name: event.target.value})} />
        </label>
        <label className={fieldLabel}>
          <span>Email</span>
          <Input type="email" value={profile.email} onChange={(event) => setProfile({...profile, email: event.target.value})} />
        </label>
        <div className="flex justify-end sm:col-span-2">
          <Button type="submit">
            <Save aria-hidden="true" />
            Save profile
          </Button>
        </div>
      </form>

      <form
        id="world-user-password-form"
        className="grid gap-3 rounded-md border border-border bg-background p-4 sm:grid-cols-[1fr_auto]"
        onSubmit={(event) => {
          event.preventDefault()
          onSetUserPassword?.({user_uri: userUri, password})
          setPassword("")
        }}
      >
        <label className={fieldLabel}>
          <span>New password</span>
          <Input type="password" value={password} onChange={(event) => setPassword(event.target.value)} />
        </label>
        <div className="flex items-end">
          <Button type="submit" disabled={!password.trim()}>
            <KeyRound aria-hidden="true" />
            Set password
          </Button>
        </div>
      </form>

      <div className="grid gap-3 rounded-md border border-border bg-background p-4">
        <label className={fieldLabel}>
          <span>Disable reason</span>
          <Input value={reason} onChange={(event) => setReason(event.target.value)} placeholder="offboarding note" />
        </label>
        <div className="flex flex-wrap gap-2">
          {state.disabled ? (
            <Button variant="secondary" onClick={() => onEnableUser?.({user_uri: userUri})}>
              <RotateCcw aria-hidden="true" />
              Enable user
            </Button>
          ) : (
            <Button variant="danger" onClick={() => onDisableUser?.({user_uri: userUri, reason})}>
              <Ban aria-hidden="true" />
              Disable user
            </Button>
          )}
          <InlineLinks links={[["Caps", state.caps_path]]} />
        </div>
      </div>
    </section>
  )
}

function AgentsTable({state}: {state: IdentitiesState}) {
  const agents = state.agents || []
  const [query, setQuery] = React.useState("")
  const filteredAgents = agents.filter((agent) => {
    const haystack = [agent.display_name, agent.name, agent.uri, agent.flavor, agent.alive ? "live" : "registered", state.workspace_uri]
      .filter(Boolean)
      .join(" ")
      .toLowerCase()

    return haystack.includes(query.trim().toLowerCase())
  })

  return (
    <section className={agentShellClass} data-world-agents-layout="directory" data-world-component="agents_table" aria-labelledby="agents-title">
      <aside className="flex min-h-0 flex-col border-b border-border bg-card lg:border-b-0 lg:border-r" aria-label="Directory">
        <div className="border-b border-border px-3 py-3">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Directory</p>
          <div className="mt-1 flex items-center justify-between gap-2">
            <h2 id="agents-title" className="text-sm font-semibold text-foreground">Users + agents</h2>
            <a className="inline-flex h-8 w-8 items-center justify-center rounded-full bg-primary text-primary-foreground" href="/identities/agents/new" aria-label="Create agent">
              <Plus aria-hidden="true" className="h-4 w-4" />
            </a>
          </div>
        </div>
        <div className="space-y-3 border-b border-border px-3 py-3">
          <div className="inline-flex rounded-[10px] border border-border bg-muted p-[3px]">
            <a className="rounded-md bg-background px-3 py-1 text-xs font-medium text-foreground shadow-sm" href="/identities/agents">Agents</a>
            <a className="rounded-md px-3 py-1 text-xs font-medium text-muted-foreground hover:text-foreground" href="/identities/users">Users</a>
          </div>
          <Input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Filter by flavor, status, workspace" aria-label="Filter by flavor, status, workspace" />
          <FilterBar active={state.filter || "agents"} flavors={state.agent_flavors || []} />
        </div>
        <div className="min-h-0 flex-1 space-y-1 overflow-y-auto p-2">
          {filteredAgents.map((agent) => (
            <a
              className="block rounded-md border border-transparent px-2.5 py-2 transition hover:border-border hover:bg-muted/60"
              href={agent.detail_path || "#"}
              key={agent.uri}
            >
              <span className="flex items-center justify-between gap-2">
                <strong className="truncate text-sm text-foreground">{agent.display_name || agent.name || agent.uri}</strong>
                <span className="flex shrink-0 items-center gap-1">
                  <CredentialBadge credential={agent.credential_status} />
                  <span className="rounded-full border border-border px-2 py-0.5 text-[11px] text-muted-foreground">{agent.flavor || "unknown"}</span>
                </span>
              </span>
              <code className="mt-1 block truncate font-mono text-[11px] text-muted-foreground">{agent.uri}</code>
            </a>
          ))}
          {filteredAgents.length === 0 && <EmptyState label="No agents in this workspace." />}
        </div>
      </aside>

      <main className={agentPanelClass}>
        <div className="space-y-4">
          <SectionHeader
            eyebrow="Agents"
            title="Agent directory"
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
          <div className="grid gap-3 sm:grid-cols-3">
            <MiniStat label="Agents" value={agents.length} />
            <MiniStat label="Live" value={agents.filter((agent) => agent.alive).length} />
            <MiniStat label="Flavors" value={(state.agent_flavors || []).length} />
          </div>
          <div className="space-y-2 rounded-lg border border-border bg-card p-4">
            <AgentRouteTabs active="Overview" />
            <div className="grid gap-2">
              {filteredAgents.map((agent) => (
                <div className="grid gap-2 rounded-md border border-border bg-background p-3 sm:grid-cols-[minmax(0,1fr)_auto]" key={agent.uri}>
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <strong className="block truncate text-foreground">{agent.display_name || agent.name || agent.uri}</strong>
                      <CredentialBadge credential={agent.credential_status} />
                    </div>
                    <code className={codeClass}>{agent.uri}</code>
                  </div>
                  <InlineLinks
                    links={[
                      ["Overview", agent.detail_path],
                      ["Config", agent.config_path],
                      ["Keys", agent.api_keys_path],
                      ["Caps", agent.caps_path],
                      ["Extensions", agent.extensions_path],
                    ]}
                  />
                </div>
              ))}
              {filteredAgents.length === 0 && <EmptyState label="No agents in this workspace." />}
            </div>
          </div>
        </div>
      </main>
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
      {state.entity_kind === "agent" && <AgentRouteTabs active="Caps" agentUri={state.entity_uri} />}
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

  // F2: a deleted / never-existed agent renders a clean not-found state instead
  // of a hollow shell of "—"/"unknown" rows.
  if (state.agent_not_found) {
    return (
      <section className={surfaceClass} data-world-component="agent_detail" aria-labelledby="agent-detail-title">
        <SectionHeader eyebrow="Agent" title="Agent detail" />
        <code className={uriClass}>{state.agent_uri}</code>
        <EmptyState label="该 agent 不存在（可能已被删除）。" />
        <div>
          <a className="text-primary hover:underline" href="/identities/agents">
            ← 返回 agent 列表
          </a>
        </div>
      </section>
    )
  }

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
      <AgentRouteTabs active="Overview" agentUri={state.agent_uri} />
      {/* F4: a delete failure (e.g. agent still bound to a live session) now
          surfaces ON the detail page where the Delete button lives, instead of
          being dropped on the list route the user already navigated away from. */}
      {state.action_error && (
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
          {state.action_error}
        </p>
      )}
      <dl className="grid grid-cols-1 gap-2 sm:grid-cols-2">
        {rows.map(([label, value]) => (
          <div className="flex justify-between gap-3 rounded-md border border-border bg-background px-3 py-2" key={label}>
            <dt className="text-xs font-medium text-muted-foreground">{label}</dt>
            <dd className="text-sm text-foreground">{value}</dd>
          </div>
        ))}
        {/* #160 — credential status (owner + ws-admin only; absent otherwise). */}
        {state.credential_status?.status && (
          <div className="flex items-center justify-between gap-3 rounded-md border border-border bg-background px-3 py-2" data-world-component="agent_credential_status">
            <dt className="text-xs font-medium text-muted-foreground">Credential</dt>
            <dd className="flex flex-col items-end gap-1 text-right">
              <CredentialBadge credential={state.credential_status} showNa />
              {state.credential_status.detail && (
                <span className="text-[11px] text-muted-foreground">{state.credential_status.detail}</span>
              )}
              {state.credential_status.expires_at && (
                <span className="text-[11px] text-muted-foreground">
                  expires {new Date(state.credential_status.expires_at).toLocaleString()}
                </span>
              )}
            </dd>
          </div>
        )}
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
                <dd className="text-sm text-foreground truncate max-w-[200px]" title={formatConfigValue(f.value)}>
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
  const flavors = allAgentFlavors(state)
  const [creating, setCreating] = React.useState(false)
  const [form, setForm] = React.useState({
    flavor: state.default_flavor || flavors[0] || "cc",
    name: "",
    cwd: "",
    cwdMode: "default" as "default" | "custom",
    caps: "",
    with_pty: false,
    configFields: {} as Record<string, string>,
  })
  const preview = form.name ? previewAgentUri(state.workspace_uri, form.name) : state.preview_uri || "<agent-uri>"

  const cwdRequired =
    (state.cwd_required_flavors || []).includes(form.flavor) ||
    (form.with_pty && (state.cwd_required_with_pty_flavors || []).includes(form.flavor))

  // F6: py requires a `script` config field. Mark it `*` and block Create when
  // empty, so the operator never submits and hits the raw `:missing_script` error.
  const scriptRequired = (state.script_required_flavors || []).includes(form.flavor)
  const allowedCwdRoots = state.allowed_project_cwd_roots || []
  const customCwdDisabled = allowedCwdRoots.length === 0
  const customCwdUnavailable = form.cwdMode === "custom" && customCwdDisabled
  const customCwdMissing = form.cwdMode === "custom" && !form.cwd.trim()

  // M4: flavor-specific schema for dynamic create fields
  const flavorSchema = createSchemaForFlavor(form.flavor, (state.config_schemas || {})[form.flavor])
  const requiredConfigKeys = Array.from(new Set([
    ...flavorSchema.filter((f) => f.required).map((f) => f.key),
    ...(scriptRequired ? ["script"] : []),
  ]))
  const missingRequiredConfigKeys = requiredConfigKeys.filter((key) => !(form.configFields[key] || "").trim())
  const configFieldRequired = (key: string) => requiredConfigKeys.includes(key)

  // Light client validation; the authoritative parse runs server-side on submit.
  const capTokens = form.caps.split(",").map((c) => c.trim()).filter(Boolean)
  const capsInvalid = capTokens.some((t) => !/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/.test(t))
  const submitDisabled =
    creating ||
    !form.name ||
    capsInvalid ||
    customCwdUnavailable ||
    customCwdMissing ||
    missingRequiredConfigKeys.length > 0

  // 依赖整个 state(每次 world:state 推送都是新对象),不能只依赖
  // state.create_error——连续两次相同的错误文案相等,effect 不重跑,
  // creating 会卡死导致后续提交被 submitDisabled 拦截。
  React.useEffect(() => {
    setCreating(false)
  }, [state])

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault()
    if (submitDisabled) return
    setCreating(true)

    // M4: submit flavor-specific config fields via A7 ingest pathway
    const cf = form.configFields || {}
    const filteredFields: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(cf)) {
      if (v != null && v !== "") filteredFields[k] = v
    }
    onCreateAgent?.({
      flavor: form.flavor,
      name: form.name,
      cwd: form.cwdMode === "default" ? "" : form.cwd.trim(),
      caps: form.caps,
      with_pty: form.with_pty,
      configFields: form.configFields,
      config_fields: filteredFields,
    })
  }

  return (
    <section className={surfaceClass} data-world-agents-layout="directory" data-world-component="agent_new_form" aria-labelledby="agent-new-title">
      <SectionHeader eyebrow="Provision" title="New agent" />
      {state.create_error && (
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
          {state.create_error}
        </p>
      )}
      <form
        id="world-agent-new-form"
        data-world-agent-create-form
        aria-busy={creating}
        className="grid gap-3 sm:grid-cols-2"
        onSubmit={handleSubmit}
      >
        <label className={fieldLabel}>
          <span>Flavor</span>
          <Select value={form.flavor} onChange={(event) => setForm({...form, flavor: event.target.value})}>
            {flavors.map((flavor) => (
              <option key={flavor} value={flavor}>{flavor}</option>
            ))}
          </Select>
        </label>
        <label className={fieldLabel}>
          <span>Name *</span>
          <Input value={form.name} onChange={(event) => setForm({...form, name: event.target.value})} placeholder="zhang san" />
        </label>
        <div className={`${fieldLabel} sm:col-span-2`} data-world-project-cwd-mode>
          <div className="flex items-center justify-between gap-3">
            <span>project_cwd {cwdRequired ? "*" : "(optional for this flavor)"}</span>
            <span className="rounded-md border border-border bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-muted-foreground">
              推荐默认
            </span>
          </div>

          <div className="grid gap-2 sm:grid-cols-2">
            <button
              type="button"
              data-world-project-cwd-card
              aria-pressed={form.cwdMode === "default"}
              className={[
                "grid min-h-[96px] grid-cols-[32px_minmax(0,1fr)_20px] gap-3 rounded-md border p-3 text-left transition",
                form.cwdMode === "default"
                  ? "border-primary/60 bg-primary/5 text-foreground shadow-sm"
                  : "border-border bg-background text-muted-foreground hover:border-primary/40 hover:bg-muted/30 hover:text-foreground",
              ].join(" ")}
              onClick={() => setForm({...form, cwdMode: "default", cwd: ""})}
            >
              <span className="flex size-8 items-center justify-center rounded-md border border-border bg-muted/40">
                <HardDrive className="size-4" aria-hidden="true" />
              </span>
              <span className="grid min-w-0 gap-1">
                <span className="text-sm font-semibold text-foreground">使用系统默认目录（推荐）</span>
                <span className="text-xs leading-5 text-muted-foreground">
                  系统会绑定独立 config_dir，无需填写路径。
                </span>
              </span>
              {form.cwdMode === "default" && <CheckCircle2 className="mt-0.5 size-4 text-primary" aria-hidden="true" />}
            </button>

            <button
              type="button"
              data-world-project-cwd-card
              aria-pressed={form.cwdMode === "custom"}
              disabled={customCwdDisabled}
              className={[
                "grid min-h-[96px] grid-cols-[32px_minmax(0,1fr)_20px] gap-3 rounded-md border p-3 text-left transition disabled:cursor-not-allowed disabled:opacity-60",
                form.cwdMode === "custom"
                  ? "border-primary/60 bg-primary/5 text-foreground shadow-sm"
                  : "border-border bg-background text-muted-foreground hover:border-primary/40 hover:bg-muted/30 hover:text-foreground",
              ].join(" ")}
              onClick={() => setForm({...form, cwdMode: "custom"})}
            >
              <span className="flex size-8 items-center justify-center rounded-md border border-border bg-muted/40">
                {customCwdDisabled ? (
                  <Ban className="size-4" aria-hidden="true" />
                ) : (
                  <FolderLock className="size-4" aria-hidden="true" />
                )}
              </span>
              <span className="grid min-w-0 gap-1">
                <span className="text-sm font-semibold text-foreground">使用自定义项目目录</span>
                <span className="text-xs leading-5 text-muted-foreground">
                  {customCwdDisabled
                    ? "当前未开放自定义项目目录。"
                    : "选择 ezagent 服务所在机器上的项目路径。"}
                </span>
              </span>
              {form.cwdMode === "custom" && <CheckCircle2 className="mt-0.5 size-4 text-primary" aria-hidden="true" />}
            </button>
          </div>

          {form.cwdMode === "custom" && allowedCwdRoots.length > 0 && (
            <div className="grid gap-2 rounded-md border border-border bg-muted/20 p-3">
              <label className={fieldLabel}>
                <span>允许的目录根</span>
                <Select
                  value={allowedCwdRoots.includes(form.cwd) ? form.cwd : ""}
                  onChange={(event) => setForm({...form, cwd: event.target.value})}
                >
                  <option value="">选择一个可用目录作为参考</option>
                  {allowedCwdRoots.map((root) => (
                    <option key={root} value={root}>{root}</option>
                  ))}
                </Select>
              </label>
              <Input
                value={form.cwd}
                onChange={(event) => setForm({...form, cwd: event.target.value})}
                placeholder={allowedCwdRoots[0] || "/srv/acme/storefront"}
              />
              <span className="text-xs text-muted-foreground">
                自定义 project_cwd 必须是 ezagent 服务所在机器上的路径，并且位于上面允许的目录范围内。
              </span>
            </div>
          )}
        </div>

        <label
          className="grid min-h-[64px] grid-cols-[32px_minmax(0,1fr)_auto] items-center gap-3 rounded-md border border-border bg-background p-3 text-sm"
          data-world-agent-create-pty
          htmlFor="world-agent-with-pty"
        >
          <span className="flex size-8 items-center justify-center rounded-md border border-border bg-muted/40 text-muted-foreground">
            <TerminalSquare className="size-4" aria-hidden="true" />
          </span>
          <span className="grid min-w-0 gap-1">
            <span className="font-medium text-foreground">With PTY</span>
            <span className="text-xs text-muted-foreground">Interactive terminal sidecar</span>
          </span>
          <input
            id="world-agent-with-pty"
            type="checkbox"
            checked={form.with_pty}
            onChange={(event) => setForm({...form, with_pty: event.target.checked})}
            className="size-4 rounded border-border text-primary focus:ring-ring"
          />
        </label>

        {/* M4: Flavor-specific config fields from schema (A4/A7 enabled) */}
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
                    {configFieldRequired(f.key) && <span className="text-destructive"> *</span>}
                    {f.help && <span className="ml-1 text-[10px] text-muted-foreground">({f.help})</span>}
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
                      placeholder={fieldPlaceholder(f)}
                    />
                  ) : (
                    <Input
                      value={form.configFields[f.key] || ""}
                      onChange={(e) => setForm({...form, configFields: {...form.configFields, [f.key]: e.target.value}})}
                      className="font-mono text-xs"
                      placeholder={fieldPlaceholder(f)}
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
        <div className="flex items-center justify-between gap-3 sm:col-span-2">
          <code className={codeClass}>{preview}</code>
          <Button
            type="submit"
            data-world-agent-create-submit
            disabled={submitDisabled}
          >
            {creating ? (
              <Loader2 className="animate-spin" aria-hidden="true" />
            ) : (
              <Plus aria-hidden="true" />
            )}
            {creating ? "Creating..." : "Create"}
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
        <AgentRouteTabs active="Config" agentUri={agentUri} />
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
        <AgentRouteTabs active="Config" agentUri={agentUri} />
        <p className="text-sm text-muted-foreground">Loading config…</p>
      </section>
    )
  }

  return (
    <section className={surfaceClass} data-world-component="agent_config" aria-labelledby="agent-config-title">
      <SectionHeader eyebrow="Agent" title="Agent config" />
      <code className={uriClass}>{agentUri}</code>
      <AgentRouteTabs active="Config" agentUri={agentUri} />
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
  placeholder?: string
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

function ConfigFieldWidget({field: _field, value, schemaType, options, onChange}: ConfigFieldWidgetProps) {
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

export function AgentApiKeys({
  state,
  onPutApiKey,
  onDeleteApiKey,
  defaultProvider,
}: {
  state: IdentitiesState
  onPutApiKey?: (payload: {agent_uri: string; provider: string; key: string}) => void
  onDeleteApiKey?: (payload: {agent_uri: string; provider: string}) => void
  defaultProvider?: string
}) {
  const keys = Array.isArray(state.api_keys) ? state.api_keys : []
  const error = !Array.isArray(state.api_keys) ? state.api_keys?.error : undefined
  const unsupported = !Array.isArray(state.api_keys) ? state.api_keys?.unsupported : false

  if (unsupported) {
    return (
      <section className={surfaceClass} data-world-component="agent_api_keys" aria-labelledby="api-keys-title">
        <SectionHeader eyebrow="Secrets" title="Agent API keys" />
        <code className={uriClass}>{state.agent_uri}</code>
        <AgentRouteTabs active="Keys" agentUri={state.agent_uri} />
        <EmptyState label="This agent flavor does not support API keys." />
      </section>
    )
  }

  return (
    <section className={surfaceClass} data-world-component="agent_api_keys" aria-labelledby="api-keys-title">
      <SectionHeader eyebrow="Secrets" title="Agent API keys" />
      <code className={uriClass}>{state.agent_uri}</code>
      <AgentRouteTabs active="Keys" agentUri={state.agent_uri} />
      {error && <p className="text-sm text-destructive">{error}</p>}
      <div className={tableWrapClass}>
        <table className={tableClass} id="world-api-keys-table">
          <thead className={theadClass}>
            <tr>
              <th className={thClass}>Provider</th>
              <th className={thClass}>Masked</th>
              {state.can_edit && <th className={thClass}>Actions</th>}
            </tr>
          </thead>
          <tbody className={tbodyClass}>
            {keys.map((key) => (
              <tr key={key.provider} className={rowClass}>
                <td className={tdClass}>{key.provider}</td>
                <td className={tdClass}>
                  <code className={codeClass}>{key.masked}</code>
                </td>
                {state.can_edit && (
                  <td className={tdClass}>
                    <Button
                      type="button"
                      variant="danger"
                      size="sm"
                      data-world-api-key-delete={key.provider}
                      onClick={() => {
                        if (!state.agent_uri || !key.provider) return
                        if (!window.confirm(`Delete the API key for ${key.provider}? This cannot be undone.`)) return
                        onDeleteApiKey?.({agent_uri: state.agent_uri, provider: key.provider})
                      }}
                    >
                      <Trash2 aria-hidden="true" />
                      Delete
                    </Button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
        {keys.length === 0 && !error && <EmptyState label="No stored keys." />}
      </div>
      {state.can_edit && state.agent_uri && (
        <AddApiKeyForm agentUri={state.agent_uri} onPutApiKey={onPutApiKey} defaultProvider={defaultProvider} />
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
  defaultProvider,
}: {
  agentUri: string
  onPutApiKey?: (payload: {agent_uri: string; provider: string; key: string}) => void
  defaultProvider?: string
}) {
  const [form, setForm] = React.useState({provider: defaultProvider || "", key: ""})
  const fieldLabel = "grid gap-1 text-xs font-medium text-muted-foreground"
  const provider = defaultProvider || form.provider
  const canSubmit = provider.trim() !== "" && form.key.trim() !== ""

  return (
    <form
      id="world-api-key-form"
      className="grid gap-3 border-t border-border pt-4 sm:grid-cols-2"
      onSubmit={(event) => {
        event.preventDefault()
        if (!canSubmit) return
        onPutApiKey?.({agent_uri: agentUri, provider: provider.trim(), key: form.key.trim()})
        setForm({provider: defaultProvider || "", key: ""})
      }}
    >
      <label className={fieldLabel}>
        <span>Provider *</span>
        <Input
          value={form.provider}
          onChange={(event) => {
            if (!defaultProvider) setForm({...form, provider: event.target.value})
          }}
          placeholder={defaultProvider || "deepseek"}
          autoComplete="off"
          readOnly={Boolean(defaultProvider)}
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
      <AgentRouteTabs active="Extensions" agentUri={state.agent_uri} />
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

function MiniStat({label, value}: {label: string; value: React.ReactNode}) {
  return (
    <div className="rounded-lg border border-border bg-card p-3">
      <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</span>
      <strong className="mt-1 block text-lg text-foreground">{value}</strong>
    </div>
  )
}

function AgentRouteTabs({
  active,
  agentUri,
}: {
  active: (typeof agentTabs)[number]
  agentUri?: string | null
}) {
  const encoded = agentUri ? encodeURIComponent(agentUri) : null
  const links: Record<(typeof agentTabs)[number], string | null> = {
    Overview: encoded ? `/identities/agents/${encoded}` : "/identities/agents",
    Config: encoded ? `/identities/agents/${encoded}/config` : null,
    Keys: encoded ? `/identities/agents/${encoded}/api-keys` : null,
    Caps: encoded ? `/identities/agents/${encoded}/caps` : null,
    Extensions: encoded ? `/identities/agents/${encoded}/extensions` : null,
  }

  return (
    <nav className="flex flex-wrap gap-1 rounded-[10px] border border-border bg-muted p-[3px]" aria-label="Agent detail tabs">
      {agentTabs.map((tab) => {
        const href = links[tab]
        const className =
          active === tab
            ? "rounded-md bg-background px-3 py-1 text-xs font-medium text-foreground shadow-sm"
            : "rounded-md px-3 py-1 text-xs font-medium text-muted-foreground transition hover:bg-background hover:text-foreground"

        if (!href) {
          return (
            <span className={`${className} opacity-60`} key={tab}>
              {tab}
            </span>
          )
        }

        return (
          <a className={className} href={href} aria-current={active === tab ? "page" : undefined} key={tab}>
            {tab}
          </a>
        )
      })}
    </nav>
  )
}

// #160 — enum → badge variant. authenticated=green, expiring=amber,
// expired/missing=red, n_a=dash, unknown=grey (spec §5).
const CREDENTIAL_STATUS_META: Record<string, {label: string; className: string}> = {
  authenticated: {label: "Authenticated", className: "border-emerald-500/40 bg-emerald-500/10 text-emerald-600"},
  expiring: {label: "Expiring", className: "border-amber-500/40 bg-amber-500/10 text-amber-600"},
  expired: {label: "Expired", className: "border-destructive/40 bg-destructive/10 text-destructive"},
  missing: {label: "Logged out", className: "border-destructive/40 bg-destructive/10 text-destructive"},
  n_a: {label: "—", className: "border-border bg-transparent text-muted-foreground"},
  unknown: {label: "Unknown", className: "border-border bg-muted/40 text-muted-foreground"},
}

// Compact credential badge. `:n_a` is a dash (never an alarm) and is hidden in
// list contexts (showNa=false) to keep credential-less flavors quiet.
function CredentialBadge({credential, showNa = false}: {credential?: CredentialStatus | null; showNa?: boolean}) {
  const status = credential?.status
  if (!status) return null
  if (status === "n_a" && !showNa) return null
  const meta = CREDENTIAL_STATUS_META[status] || CREDENTIAL_STATUS_META.unknown
  return (
    <span
      className={`inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-medium ${meta.className}`}
      title={credential?.detail || `Credential: ${meta.label}`}
      data-world-credential-status={status}
    >
      {meta.label}
    </span>
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
      <p className="flex items-center gap-2 text-sm text-muted-foreground">
        <span>{row.kind === "agent" ? `Agent ${row.flavor || "unknown"}` : "User"}</span>
        {row.kind === "agent" && <CredentialBadge credential={row.credential_status} />}
      </p>
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

function InfoRow({label, value}: {label: string; value: string}) {
  return (
    <div className="flex justify-between gap-3 rounded-md border border-border bg-background px-3 py-2">
      <dt className="text-xs font-medium text-muted-foreground">{label}</dt>
      <dd className="truncate text-sm text-foreground" title={value}>{value}</dd>
    </div>
  )
}

function StatusPill({tone, label}: {tone: "success" | "danger"; label: string}) {
  const classes =
    tone === "success"
      ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
      : "border-destructive/40 bg-destructive/10 text-destructive"

  return <span className={`inline-flex rounded-full border px-2 py-0.5 text-xs font-medium ${classes}`}>{label}</span>
}

function activeMatches(active: string, label: string) {
  if (label === "All") return active === "all"
  if (label === "Users") return active === "users"
  if (label === "Agents") return active === "agents"
  return active === label
}

function allAgentFlavors(state: IdentitiesState): string[] {
  return Array.from(new Set([...(state.flavors || []), ...defaultAgentFlavors]))
}

function fieldPlaceholder(field: ConfigSchemaField): string {
  if (field.placeholder) return field.placeholder
  if (field.default != null && field.default !== "") return String(field.default)
  return ""
}

function createSchemaForFlavor(flavor: string, schema?: ConfigSchemaField[]): ConfigSchemaField[] {
  const current = schema || []
  const fallback = defaultCreateSchema[flavor] || []
  const seen = new Set(current.map((field) => field.key))

  return [...current, ...fallback.filter((field) => !seen.has(field.key))]
}

function previewAgentUri(workspaceUri: string | null | undefined, name: string) {
  const workspace = workspaceUri?.replace("workspace://", "") || "system"
  return `entity://${workspace}/agent/${name}`
}

function previewUserUri(workspaceUri: string | null | undefined, name: string) {
  const workspace = workspaceUri?.replace("workspace://", "") || "system"
  return `entity://${workspace}/user/${name}`
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
