import React from "react"
import {Activity, Database, Route, Send, Settings, ShieldCheck, TableProperties, Trash2} from "lucide-react"

import {Badge, Button, EmptyState, Input, Stat} from "./ui/primitives"

type DataRow = Record<string, unknown>

export type AdminState = {
  audit_rows?: DataRow[]
  bindings?: DataRow[]
  bridges?: DataRow[]
  cc_orchestrator_status?: unknown
  component?: string
  default_grants?: DataRow[]
  entities?: DataRow[]
  external_mirror_bindings?: DataRow[]
  grantable?: unknown[]
  kpis?: Record<string, number>
  path?: string
  rules?: DataRow[]
  session_uri?: string | null
  settings?: {
    error?: string
    smtp?: Record<string, unknown>
    smtp_configured?: boolean
    smtp_flash?: string | null
    smtp_test_recipient?: string
    smtp_test_result?: string | null
  }
  snapshots?: DataRow[]
  templates?: DataRow[]
  title?: string
  workspace_uri?: string | null
}

// Admin 区子页导航（FP5 入口审计）：此前这些子页在 UI 里无任何可见入口,只能靠
// ⌘K 命令面板或直接敲 URL 到达。在每个 admin 面顶部挂一行子导航,当前页高亮。
const ADMIN_NAV: Array<{component: string; label: string; href: string}> = [
  {component: "dashboard", label: "Dashboard", href: "/admin"},
  {component: "observability", label: "Observability", href: "/admin/logs"},
  {component: "entity_registry", label: "Registry", href: "/admin/registry"},
  {component: "snapshots", label: "Snapshots", href: "/admin/snapshots"},
  {component: "templates", label: "Templates", href: "/admin/templates"},
  {component: "caps_admin", label: "Capabilities", href: "/admin/caps"},
  {component: "authz_audit", label: "Authz Audit", href: "/admin/audit/authz"},
  {component: "settings", label: "Settings", href: "/admin/settings"},
  {component: "routing", label: "Routing", href: "/admin/routing"},
]

function AdminNav({current}: {current?: string}) {
  const active = current || "dashboard"
  return (
    <nav className="flex flex-wrap gap-1.5" aria-label="Admin sections">
      {ADMIN_NAV.map((item) => {
        const isActive = active === item.component
        return (
          <a
            key={item.component}
            href={item.href}
            aria-current={isActive ? "page" : undefined}
            className={
              isActive
                ? "rounded-md bg-accent px-3 py-1.5 text-sm font-medium text-accent-foreground"
                : "rounded-md px-3 py-1.5 text-sm font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
            }
          >
            {item.label}
          </a>
        )
      })}
    </nav>
  )
}

function adminBody(state: AdminState, onAction: (action: string, args: Record<string, unknown>) => void) {
  switch (state.component) {
    case "observability":
      return <Observability state={state} />
    case "entity_registry":
      return <EntityRegistry state={state} />
    case "snapshots":
      return <Snapshots state={state} />
    case "templates":
      return <Templates state={state} />
    case "caps_admin":
      return <CapsAdmin state={state} />
    case "authz_audit":
      return <AuthzAudit state={state} />
    case "settings":
      return <SettingsPanel state={state} onAction={onAction} />
    case "routing":
      return <RoutingPanel state={state} />
    default:
      return <Dashboard state={state} />
  }
}

export function AdminSurface({
  state,
  onAction = () => undefined,
}: {
  state: AdminState
  onAction?: (action: string, args: Record<string, unknown>) => void
}) {
  // external_mirror 是 session 级子页（/admin/sessions/:id/external_mirror,经 Sessions
  // 表进入,有自己的 breadcrumb),不属顶层 admin 区 → 不挂 admin 子导航。
  if (state.component === "external_mirror") {
    return <ExternalMirror state={state} onAction={onAction} />
  }

  return (
    <section className="grid h-full min-h-0 overflow-hidden border-y border-border bg-background text-foreground lg:grid-cols-[232px_minmax(0,1fr)]" data-world-manage-layout>
      <aside className="min-h-0 overflow-y-auto border-b border-border bg-card p-3 lg:border-b-0 lg:border-r" aria-label="Manage sections">
        <div className="mb-3 px-1">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Manage</p>
          <h2 className="text-sm font-semibold text-foreground">Admin</h2>
        </div>
        <nav className="grid gap-1 manage-nav">
          {[
            ["Workspace", "/workspaces", "members, templates, routing"],
            ["Plugins", "/plugins", "routes, flavors, installed apps"],
            ["Integrations", "/plugins/feishu/bindings", "Feishu, mirrors, connectors"],
            ["Admin", "/admin", "runtime and registry"],
            ["Access", "/admin/caps", "caps and authz audit"],
            ["System", "/admin/settings", "SMTP, routing, diagnostics"],
          ].map(([label, href, hint]) => {
            const active = adminManageActive(state.component, label)
            return (
              <a
                key={label}
                href={href}
                aria-current={active ? "page" : undefined}
                className={
                  active
                    ? "rounded-md border border-primary/30 bg-accent/70 px-3 py-2 text-sm font-medium text-accent-foreground"
                    : "rounded-md border border-transparent px-3 py-2 text-sm font-medium text-muted-foreground transition hover:border-border hover:bg-muted hover:text-foreground"
                }
              >
                <span className="block text-foreground">{label}</span>
                <span className="mt-0.5 block text-xs font-normal text-muted-foreground">{hint}</span>
              </a>
            )
          })}
        </nav>
      </aside>
      <main className="min-h-0 overflow-y-auto p-4">
        <div className="space-y-4">
          <AdminNav current={state.component} />
          {adminBody(state, onAction)}
        </div>
      </main>
    </section>
  )
}

function adminManageActive(component: string | undefined, label: string) {
  if (label === "Access") return component === "caps_admin" || component === "authz_audit"
  if (label === "System") return component === "settings" || component === "routing"
  return label === "Admin" && !["caps_admin", "authz_audit", "settings", "routing"].includes(component || "")
}

// ---------------------------------------------------------------------------
// Shared shadcn chrome + a typed table (PR-6: purpose-built columns replace the
// old generic key-auto-derive DataTable + JSON dumps).
// ---------------------------------------------------------------------------

const tableWrapClass = "overflow-x-auto rounded-md border border-border"
const tableClass = "w-full border-collapse text-sm"
const theadClass = "bg-muted/50 text-muted-foreground"
const tbodyClass = "divide-y divide-border"
const thClass = "px-3 py-2 text-left font-medium"
const tdClass = "px-3 py-2 align-top"
const rowClass = "hover:bg-muted/30"
const monoCell = "font-mono text-xs text-foreground"
const mutedMono = "font-mono text-xs text-muted-foreground"

// FP5 入口完善：admin 各表的 URI 此前是死文本。把 entity/session/workspace URI 映射到
// world 内对应详情面,让操作员能从 Registry/Snapshots/Audit 等直接点进去下钻。
// 无对应面的 URI(如 system://、template:// 等)返回 null → 保持纯文本(不假装可点)。
function worldPathForUri(uri: unknown): string | null {
  if (typeof uri !== "string" || uri === "") return null
  if (/^entity:\/\/[^/]+\/agent\//.test(uri)) return `/identities/agents/${encodeURIComponent(uri)}`
  if (/^entity:\/\/[^/]+\/user\//.test(uri)) return `/identities/users/${encodeURIComponent(uri)}/caps`
  if (uri.startsWith("session://")) return `/sessions?session=${encodeURIComponent(uri)}`
  const ws = uri.match(/^workspace:\/\/(.+)$/)
  if (ws) return `/workspaces/${encodeURIComponent(ws[1])}`
  return null
}

function UriCell({uri, muted = false}: {uri: unknown; muted?: boolean}) {
  const text = s(uri)
  const href = worldPathForUri(uri)
  const cls = muted ? mutedMono : monoCell
  if (!href) return <code className={cls}>{text}</code>
  return (
    <a href={href} className={`${cls} underline decoration-dotted underline-offset-2 hover:text-primary hover:decoration-solid`} title={`打开 ${text}`}>
      {text}
    </a>
  )
}

function Surface({component, children}: {component: string; children: React.ReactNode}) {
  return (
    <section className="space-y-4 rounded-lg border border-border bg-card p-5 text-card-foreground" data-world-component={component}>
      {children}
    </section>
  )
}

function SectionHeader({eyebrow, title, icon, compact = false}: {eyebrow: string; title: string; icon?: React.ReactNode; compact?: boolean}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div>
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{eyebrow}</p>
        <h2 className={compact ? "text-base font-semibold text-foreground" : "text-lg font-semibold text-foreground"}>{title}</h2>
      </div>
      {icon && <span className="text-muted-foreground">{icon}</span>}
    </div>
  )
}

function KpiGrid({children}: {children: React.ReactNode}) {
  return <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">{children}</div>
}

type Column<T> = {header: string; cell: (row: T) => React.ReactNode; className?: string}

// A purpose-built table: explicit, typed columns — not auto-derived from the
// first six object keys. Surfaces the data builders' rescue rows ([{error}]) as
// an inline message instead of a misleading empty/garbled table.
function Table<T extends DataRow>({columns, rows, empty}: {columns: Column<T>[]; rows: T[]; empty?: string}) {
  const error = errorOf(rows)
  if (error) return <p className="text-sm text-destructive">{error}</p>

  return (
    <div className={tableWrapClass}>
      <table className={tableClass}>
        <thead className={theadClass}>
          <tr>
            {columns.map((column) => (
              <th key={column.header} className={`${thClass} ${column.className || ""}`}>
                {column.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className={tbodyClass}>
          {rows.map((row, index) => (
            <tr key={index} className={rowClass}>
              {columns.map((column) => (
                <td key={column.header} className={`${tdClass} ${column.className || ""}`}>
                  {column.cell(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      {rows.length === 0 && <EmptyState label={empty || "No rows."} />}
    </div>
  )
}

// Data builders return `[{error: "..."}]` on a rescue; detect it so the table
// shows the failure rather than a one-column "error" mystery table.
function errorOf(rows: DataRow[] | undefined): string | null {
  if (rows && rows.length === 1 && typeof rows[0].error === "string") return rows[0].error as string
  return null
}

function AliveBadge({alive}: {alive: unknown}) {
  return alive ? <Badge tone="success">live</Badge> : <Badge tone="default">down</Badge>
}

function AuthzBadge({authz}: {authz: unknown}) {
  const value = String(authz ?? "")
  if (value === "granted" || value === "grant" || value === "allow") return <Badge tone="success">{value}</Badge>
  if (value === "denied" || value === "deny" || value === "reject") return <Badge tone="danger">{value}</Badge>
  return <Badge tone="default">{value || "—"}</Badge>
}

function s(value: unknown): string {
  return value == null ? "—" : String(value)
}

// ---------------------------------------------------------------------------
// Surfaces
// ---------------------------------------------------------------------------

function Dashboard({state}: {state: AdminState}) {
  const kpis = state.kpis || {}
  const status = state.cc_orchestrator_status

  return (
    <Surface component="dashboard">
      <SectionHeader eyebrow="Admin" title="Dashboard" />
      <KpiGrid>
        <Stat icon={<Database className="h-4 w-4" />} label="Kinds" value={kpis.kinds ?? 0} />
        <Stat icon={<Activity className="h-4 w-4" />} label="Sessions" value={kpis.sessions ?? 0} />
        <Stat icon={<Database className="h-4 w-4" />} label="Workspaces" value={kpis.workspaces ?? 0} />
        <Stat icon={<ShieldCheck className="h-4 w-4" />} label="Entities" value={kpis.entities ?? 0} />
        <Stat icon={<Route className="h-4 w-4" />} label="Agents" value={kpis.agents ?? 0} />
      </KpiGrid>

      <div className="space-y-2">
        <h3 className="text-sm font-semibold text-foreground">CC orchestrator</h3>
        <OrchestratorStatus status={status} />
      </div>
    </Surface>
  )
}

function orchestratorTone(state: string): "default" | "success" | "warning" | "danger" {
  if (state === "ok") return "success"
  if (state === "partial") return "warning"
  if (state === "missing" || state === "unavailable") return "danger"
  return "default"
}

function OrchestratorStatus({status}: {status: unknown}) {
  if (status == null || typeof status === "string") {
    const value = String(status ?? "unavailable")
    return <Badge tone={orchestratorTone(value)}>{value}</Badge>
  }

  // Anything non-object (or an array, e.g. a serialized tuple) — show the
  // raw value as a degraded badge rather than an index-keyed dump.
  if (typeof status !== "object" || Array.isArray(status)) {
    return <Badge tone="warning">{s(status)}</Badge>
  }

  const {state, ...rest} = status as Record<string, unknown>
  const entries = Object.entries(rest)

  return (
    <div className="space-y-2">
      {state != null && <Badge tone={orchestratorTone(String(state))}>{String(state)}</Badge>}
      {entries.length > 0 && (
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {entries.map(([key, value]) => (
            <div className="rounded-md border border-border bg-background p-2 text-xs" key={key}>
              <span className="block text-muted-foreground">{key}</span>
              <code className="font-mono text-foreground break-all">{typeof value === "object" ? JSON.stringify(value) : s(value)}</code>
            </div>
          ))}
        </div>
      )}
      {state == null && entries.length === 0 && <Badge tone="default">empty</Badge>}
    </div>
  )
}

function Observability({state}: {state: AdminState}) {
  return (
    <Surface component="observability">
      <SectionHeader eyebrow="Runtime" title="Observability" />
      <KpiGrid>
        <Stat icon={<Activity className="h-4 w-4" />} label="Audit rows" value={(state.audit_rows || []).length} />
        <Stat icon={<Database className="h-4 w-4" />} label="Snapshots" value={(state.snapshots || []).length} />
        <Stat icon={<ShieldCheck className="h-4 w-4" />} label="Bridges" value={(state.bridges || []).length} />
      </KpiGrid>
      <div className="space-y-3">
        <SectionHeader eyebrow="Recent" title="Invocations" icon={<TableProperties className="h-4 w-4" />} compact />
        <AuditTable rows={state.audit_rows || []} />
      </div>
    </Surface>
  )
}

function EntityRegistry({state}: {state: AdminState}) {
  return (
    <Surface component="entity_registry">
      <SectionHeader eyebrow="Runtime" title="Entity registry" icon={<TableProperties className="h-4 w-4" />} />
      <Table
        rows={state.entities || []}
        empty="No registered kinds."
        columns={[
          {header: "URI", cell: (row) => <UriCell uri={row.uri} />},
          {header: "Scheme", cell: (row) => <Badge tone="info">{s(row.scheme)}</Badge>},
          {header: "Status", cell: (row) => <AliveBadge alive={row.alive} />},
          {header: "PID", cell: (row) => <code className={mutedMono}>{s(row.pid)}</code>},
        ]}
      />
    </Surface>
  )
}

function Snapshots({state}: {state: AdminState}) {
  return (
    <Surface component="snapshots">
      <SectionHeader eyebrow="Persistence" title="Snapshots" icon={<TableProperties className="h-4 w-4" />} />
      <Table
        rows={state.snapshots || []}
        empty="No snapshots."
        columns={[
          {header: "URI", cell: (row) => <UriCell uri={row.uri} />},
          {header: "Kind", cell: (row) => s(row.kind_type)},
          {header: "Version", cell: (row) => <Badge tone="default">{s(row.version)}</Badge>},
          {header: "Workspace", cell: (row) => <UriCell uri={row.workspace_uri} muted />},
          {header: "Updated", cell: (row) => <span className={mutedMono}>{s(row.updated_at)}</span>},
        ]}
      />
    </Surface>
  )
}

function Templates({state}: {state: AdminState}) {
  return (
    <Surface component="templates">
      <SectionHeader eyebrow="Catalog" title="Templates" icon={<TableProperties className="h-4 w-4" />} />
      <Table
        rows={state.templates || []}
        empty="No templates registered."
        columns={[
          {header: "URI", cell: (row) => <UriCell uri={row.uri} />},
          {header: "Status", cell: (row) => <AliveBadge alive={row.alive} />},
        ]}
      />
    </Surface>
  )
}

function AuthzAudit({state}: {state: AdminState}) {
  return (
    <Surface component="authz_audit">
      <SectionHeader eyebrow="Security" title="Authz audit" icon={<ShieldCheck className="h-4 w-4" />} />
      <AuditTable rows={state.audit_rows || []} />
    </Surface>
  )
}

function AuditTable({rows}: {rows: DataRow[]}) {
  return (
    <Table
      rows={rows}
      empty="No invocations recorded."
      columns={[
        {header: "Target", cell: (row) => <UriCell uri={row.target} />},
        {header: "Action", cell: (row) => s(row.action)},
        {header: "Authz", cell: (row) => <AuthzBadge authz={row.authz} />},
        {header: "Duration", cell: (row) => <span className="tabular-nums">{row.duration_us != null ? `${row.duration_us} µs` : "—"}</span>},
        {header: "At", cell: (row) => <span className={mutedMono}>{s(row.inserted_at)}</span>},
      ]}
    />
  )
}

function CapsAdmin({state}: {state: AdminState}) {
  const grantable = (state.grantable || []) as unknown[]
  const defaults = (state.default_grants || []) as DataRow[]
  const defaultsError = errorOf(defaults)

  return (
    <Surface component="caps_admin">
      <SectionHeader eyebrow="Security" title="Capabilities" icon={<ShieldCheck className="h-4 w-4" />} />

      <div className="space-y-2">
        <SectionHeader eyebrow="Catalog" title="Grantable" compact />
        {grantable.length === 0 ? (
          <EmptyState label="No grantable capabilities." />
        ) : (
          <div className="flex flex-wrap gap-1.5">
            {grantable.map((cap, index) => (
              <code key={index} className="rounded-md border border-border bg-muted/50 px-2 py-1 font-mono text-xs text-muted-foreground">
                {capLabel(cap)}
              </code>
            ))}
          </div>
        )}
      </div>

      <div className="space-y-2">
        <SectionHeader eyebrow="Defaults" title="Default grants by kind" compact />
        {defaultsError ? (
          <p className="text-sm text-destructive">{defaultsError}</p>
        ) : defaults.length === 0 ? (
          <EmptyState label="No default grants." />
        ) : (
          <div className="space-y-2">
            {defaults.map((entry, index) => (
              <div key={index} className="rounded-md border border-border bg-background p-3">
                <code className="text-xs font-semibold text-foreground">{s(entry.kind)}</code>
                <div className="mt-2 flex flex-wrap gap-1.5">
                  {((entry.caps as unknown[]) || []).map((cap, capIndex) => (
                    <code key={capIndex} className="rounded bg-muted px-1.5 py-0.5 font-mono text-[11px] text-muted-foreground">
                      {capLabel(cap)}
                    </code>
                  ))}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </Surface>
  )
}

function capLabel(cap: unknown): string {
  if (typeof cap === "string") return cap
  if (cap && typeof cap === "object") {
    const c = cap as Record<string, unknown>
    const parts = [c.kind, c.behavior, c.action].filter(Boolean).map(String)
    if (parts.length > 0) return parts.join(".")
    return JSON.stringify(cap)
  }
  return String(cap)
}

function SettingsPanel({
  state,
  onAction,
}: {
  state: AdminState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const settings = state.settings || {}
  const smtp = settings.smtp || {}
  const [form, setForm] = React.useState({
    host: String(smtp.host || ""),
    port: String(smtp.port || ""),
    username: String(smtp.username || ""),
    password: "",
    from_address: String(smtp.from_address || ""),
    tls: smtp.tls !== false,
  })
  const [recipient, setRecipient] = React.useState(settings.smtp_test_recipient || "")

  React.useEffect(() => {
    const next = state.settings?.smtp || {}
    setForm((current) => ({
      ...current,
      host: String(next.host || ""),
      port: String(next.port || ""),
      username: String(next.username || ""),
      from_address: String(next.from_address || ""),
      tls: next.tls !== false,
      password: "",
    }))
    setRecipient(state.settings?.smtp_test_recipient || "")
  }, [state.settings])

  const fieldLabel = "grid gap-1 text-xs font-medium text-muted-foreground"

  return (
    <Surface component="settings">
      <SectionHeader eyebrow="Config" title="Settings" icon={<Settings className="h-4 w-4" />} />
      {settings.error && <p className="text-sm text-destructive">{settings.error}</p>}
      <form
        id="world-smtp-form"
        className="grid gap-3 sm:grid-cols-2"
        onSubmit={(event) => {
          event.preventDefault()
          onAction("admin.smtp.save", {smtp: form})
        }}
      >
        <label className={fieldLabel}>
          Host
          <Input value={form.host} onChange={(event) => setForm({...form, host: event.target.value})} />
        </label>
        <label className={fieldLabel}>
          Port
          <Input value={form.port} onChange={(event) => setForm({...form, port: event.target.value})} />
        </label>
        <label className={fieldLabel}>
          Username
          <Input value={form.username} onChange={(event) => setForm({...form, username: event.target.value})} />
        </label>
        <label className={fieldLabel}>
          Password
          <Input
            type="password"
            placeholder={smtp.has_password ? "saved" : ""}
            value={form.password}
            onChange={(event) => setForm({...form, password: event.target.value})}
          />
        </label>
        <label className={fieldLabel}>
          From address
          <Input value={form.from_address} onChange={(event) => setForm({...form, from_address: event.target.value})} />
        </label>
        <label className="flex items-center gap-2 text-sm text-foreground">
          <input type="checkbox" checked={form.tls} onChange={(event) => setForm({...form, tls: event.target.checked})} />
          TLS
        </label>
        <div className="flex items-center gap-3 sm:col-span-2">
          <Button variant="primary" type="submit">
            Save SMTP
          </Button>
          <span className="text-xs text-muted-foreground">{settings.smtp_configured ? "configured" : "not configured"}</span>
        </div>
      </form>
      {settings.smtp_flash && <p className="text-sm text-muted-foreground">{settings.smtp_flash}</p>}

      <form
        id="world-smtp-test-form"
        className="flex flex-wrap items-end gap-3"
        onSubmit={(event) => {
          event.preventDefault()
          onAction("admin.smtp.test", {recipient})
        }}
      >
        <label className={fieldLabel}>
          Test recipient
          <Input
            value={recipient}
            onChange={(event) => {
              setRecipient(event.target.value)
              onAction("admin.smtp.update_recipient", {recipient: event.target.value})
            }}
          />
        </label>
        <Button type="submit">
          <Send size={16} />
          Send test
        </Button>
      </form>
      {settings.smtp_test_result && (
        <p className={settings.smtp_test_result.startsWith("ok:") ? "text-sm text-emerald-600 dark:text-emerald-400" : "text-sm text-destructive"}>
          {settings.smtp_test_result}
        </p>
      )}
    </Surface>
  )
}

function RoutingPanel({state}: {state: AdminState}) {
  const rules = (state.rules || []) as DataRow[]
  const rulesError = errorOf(rules)

  return (
    <Surface component="routing">
      <SectionHeader eyebrow="Routing" title="Routing" icon={<Route className="h-4 w-4" />} />

      <div className="space-y-2">
        <SectionHeader eyebrow="Mention routing" title="Rules" compact />
        {rulesError ? (
          <p className="text-sm text-destructive">{rulesError}</p>
        ) : rules.length === 0 ? (
          <EmptyState label="No mention routing rules." />
        ) : (
          <ul className="space-y-1.5">
            {rules.map((rule, index) => (
              <li key={index} className="flex items-center justify-between gap-2 rounded-md border border-border p-2">
                <div className="min-w-0">
                  <code className="block truncate font-mono text-xs text-foreground">{s(rule.matcher ?? rule.source)}</code>
                  <span className="block truncate text-xs text-muted-foreground">
                    {Array.isArray(rule.receivers) ? (rule.receivers as string[]).join(", ") : s(rule.receivers_text)}
                  </span>
                </div>
                {rule.enabled === false ? <Badge tone="default">disabled</Badge> : <Badge tone="success">enabled</Badge>}
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="space-y-2">
        <SectionHeader eyebrow="External mirror" title="Bindings" compact />
        <ExternalMirrorTable rows={state.external_mirror_bindings || []} />
      </div>
    </Surface>
  )
}

function ExternalMirror({
  state,
  onAction,
}: {
  state: AdminState
  onAction: (action: string, args: Record<string, unknown>) => void
}) {
  const sessionUri = s(state.session_uri)
  const [adapterId, setAdapterId] = React.useState("feishu")
  const [targetId, setTargetId] = React.useState("")
  const fieldLabel = "grid gap-1 text-xs font-medium text-muted-foreground"

  return (
    <Surface component="external_mirror">
      <SectionHeader eyebrow="Session" title="External mirror" />
      <code className="block w-fit rounded-md border border-border bg-muted/50 px-2 py-1 font-mono text-xs text-muted-foreground">
        {sessionUri}
      </code>
      <form
        id="world-external-mirror-bind-form"
        className="flex flex-wrap items-end gap-3"
        onSubmit={(event) => {
          // phx-update="ignore" island: native form POST is swallowed by
          // LiveView, so we preventDefault + dispatch through onAction (pushEvent).
          event.preventDefault()
          if (!sessionUri || !targetId.trim()) return
          onAction("external_mirror.bind", {
            session_uri: sessionUri,
            adapter_id: adapterId.trim() || "feishu",
            target_id: targetId.trim(),
          })
          setTargetId("")
        }}
      >
        <label className={fieldLabel}>
          Adapter
          <Input value={adapterId} onChange={(event) => setAdapterId(event.target.value)} />
        </label>
        <label className={fieldLabel}>
          Target (chat id)
          <Input placeholder="oc_..." value={targetId} onChange={(event) => setTargetId(event.target.value)} />
        </label>
        <Button variant="primary" type="submit">
          Bind
        </Button>
      </form>
      <ExternalMirrorTable
        rows={state.bindings || []}
        onUnbind={(row) =>
          onAction("external_mirror.unbind", {
            session_uri: sessionUri,
            adapter_id: s(row.adapter_id),
            target_id: s(row.target_id),
          })
        }
      />
    </Surface>
  )
}

function ExternalMirrorTable({rows, onUnbind}: {rows: DataRow[]; onUnbind?: (row: DataRow) => void}) {
  return (
    <Table
      rows={rows}
      empty="No external mirror bindings."
      columns={[
        {header: "Adapter", cell: (row) => <Badge tone="info">{s(row.adapter_id)}</Badge>},
        {header: "Target", cell: (row) => <code className={monoCell}>{s(row.target_id)}</code>},
        {header: "Workspace", cell: (row) => <UriCell uri={row.workspace_uri} muted />},
        ...(rows.some((row) => "session_uri" in row)
          ? [{header: "Session", cell: (row: DataRow) => <UriCell uri={row.session_uri} muted />}]
          : []),
        {header: "Bound", cell: (row) => <span className={mutedMono}>{s(row.bound_at)}</span>},
        ...(onUnbind
          ? [
              {
                header: "",
                cell: (row: DataRow) => (
                  <button
                    type="button"
                    title="Unbind"
                    className="inline-flex items-center justify-center rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-destructive"
                    onClick={() => onUnbind(row)}
                  >
                    <Trash2 size={16} />
                  </button>
                ),
              },
            ]
          : []),
      ]}
    />
  )
}
