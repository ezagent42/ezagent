import React from "react"
import {Activity, Database, Route, Send, Settings, ShieldCheck, TableProperties} from "lucide-react"

import {Badge, Button, Card, EmptyState, Input, Stat} from "./ui/primitives"

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
  settings?: {
    error?: string
    smtp?: Record<string, unknown>
    smtp_configured?: boolean
    smtp_flash?: string | null
    smtp_test_recipient?: string
    smtp_test_result?: string | null
  }
  snapshots?: Record<string, unknown>[]
  templates?: Record<string, unknown>[]
  title?: string
  workspace_uri?: string | null
}

export function AdminSurface({
  state,
  onAction = () => undefined,
}: {
  state: AdminState
  onAction?: (action: string, args: Record<string, unknown>) => void
}) {
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
      return <SettingsPanel state={state} onAction={onAction} />
    case "routing":
      return <RoutingPanel state={state} />
    case "external_mirror":
      return <ExternalMirror state={state} />
    default:
      return <Dashboard state={state} />
  }
}

// Surface section container + header (shadcn token-based; replaces world-section
// / world-section-header BEM). PR-4 restyle only — structure unchanged.
function Surface({
  component,
  children,
}: {
  component: string
  children: React.ReactNode
}) {
  return (
    <section className="space-y-4 rounded-lg border border-border bg-card p-5 text-card-foreground" data-world-component={component}>
      {children}
    </section>
  )
}

function SectionHeader({
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
  return <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">{children}</div>
}

function Dashboard({state}: {state: AdminState}) {
  const kpis = state.kpis || {}

  return (
    <Surface component="dashboard">
      <SectionHeader eyebrow="Admin" title="Dashboard" />
      <KpiGrid>
        <Stat icon={<Database className="h-4 w-4" />} label="Kinds" value={kpis.kinds ?? 0} />
        <Stat icon={<Activity className="h-4 w-4" />} label="Sessions" value={kpis.sessions ?? 0} />
        <Stat icon={<ShieldCheck className="h-4 w-4" />} label="Entities" value={kpis.entities ?? 0} />
        <Stat icon={<Route className="h-4 w-4" />} label="Agents" value={kpis.agents ?? 0} />
      </KpiGrid>
      <Json value={{cc_orchestrator_status: state.cc_orchestrator_status}} />
    </Surface>
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
      <DataTable component="observability-audit" title="Recent audit" rows={state.audit_rows || []} nested />
    </Surface>
  )
}

function CapsAdmin({state}: {state: AdminState}) {
  const rows = [
    ...((state.grantable || []) as unknown[]).map((entry) => ({type: "grantable", value: entry})),
    ...((state.default_grants || []) as unknown[]).map((entry) => ({type: "default", value: entry})),
  ]

  return <DataTable component="caps_admin" title="Capabilities" rows={rows} />
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
          <input
            type="checkbox"
            checked={form.tls}
            onChange={(event) => setForm({...form, tls: event.target.checked})}
          />
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
  return (
    <Surface component="routing">
      <SectionHeader eyebrow="Routing" title="Routing" icon={<Route className="h-4 w-4" />} />
      <DataTable component="routing-rules" title="Mention routing rules" rows={state.rules || []} nested />
      <DataTable component="routing-external-mirror" title="External mirror bindings" rows={state.external_mirror_bindings || []} nested />
    </Surface>
  )
}

function ExternalMirror({state}: {state: AdminState}) {
  return (
    <Surface component="external_mirror">
      <SectionHeader eyebrow="Session" title="External mirror" />
      <code className="block rounded-md border border-border bg-muted/50 px-2 py-1 text-xs text-muted-foreground">{state.session_uri}</code>
      <DataTable component="external-mirror-bindings" title="Bindings" rows={state.bindings || []} nested />
    </Surface>
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
  const cols = columns.length > 0 ? columns : ["value"]

  // A nested table sits inside a parent Surface (just spacing); a top-level one
  // owns the card chrome. Either way it carries a single data-world-component.
  const containerClass = nested
    ? "space-y-3"
    : "space-y-3 rounded-lg border border-border bg-card p-5 text-card-foreground"

  return (
    <div className={containerClass} data-world-component={component}>
      <SectionHeader eyebrow="Table" title={title} icon={<TableProperties className="h-4 w-4" />} compact />
      <div className="overflow-x-auto rounded-md border border-border">
        <table className="w-full border-collapse text-sm">
          <thead className="bg-muted/50 text-muted-foreground">
            <tr>
              {cols.map((column) => (
                <th key={column} className="px-3 py-2 text-left font-medium">
                  {column}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((row, index) => (
              <tr key={index} className="hover:bg-muted/30">
                {cols.map((column) => (
                  <td key={column} className="px-3 py-2 align-top">
                    <Cell value={columns.length > 0 ? row[column] : row} />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
        {rows.length === 0 && <EmptyState label="No rows." />}
      </div>
    </div>
  )
}

function Json({value}: {value: unknown}) {
  return (
    <pre className="overflow-x-auto rounded-md border border-border bg-muted/40 p-3 text-xs text-muted-foreground">
      {JSON.stringify(value, null, 2)}
    </pre>
  )
}

function Cell({value}: {value: unknown}) {
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return <code className="rounded bg-muted px-1 py-0.5 text-xs text-foreground">{String(value)}</code>
  }

  if (value == null) return <Badge tone="default">null</Badge>

  return <code className="rounded bg-muted px-1 py-0.5 text-xs text-foreground">{JSON.stringify(value)}</code>
}
