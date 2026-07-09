import React from "react"
import {
  Activity,
  ArrowRight,
  Database,
  LayoutDashboard,
  Plus,
  Route,
  ShieldCheck,
  Users,
} from "lucide-react"

// Overview 操作员落地页。`/` 现为独立 landing（IA convergence：Overview 是一等导航目的地，
// Chat/Sessions 在 `/sessions`）。三板块：推荐下一步（继续 session / 建 Agent / 浏览 / 建 session）、
// 关键状态（KPI，数据复用 AdminData，与 Admin Dashboard 同源）、可继续的 Sessions。
// 纯只读 + 导航，无 dispatch，自含不依赖 Admin.tsx 内部。

// ── Types ──────────────────────────────────────────────────────────
type OverviewState = {
  kpis?: Record<string, number>
  workspace_uri?: string | null
  available_sessions?: Array<{uri: string; name: string}>
  session_template_names?: string[]
}

// ── Shared token classes (match SessionsTable/Admin patterns) ──────
const card = "rounded-lg border border-border bg-card text-card-foreground"
const kpiIcon = "flex items-center gap-2 text-muted-foreground"
const sectionTitle = "text-xs font-medium uppercase tracking-wide text-muted-foreground"
const primaryBtn =
  "inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground transition hover:opacity-90"
const ghostBtn =
  "inline-flex items-center gap-1.5 rounded-md border border-border px-3 py-1.5 text-sm font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"

// ── Section 1: Recommended Next ────────────────────────────────────
function RecommendedNext({
  sessions,
  templates,
  workspaceUri,
}: {
  sessions?: Array<{uri: string; name: string}>
  templates?: string[]
  workspaceUri?: string | null
}) {
  const continueSession = sessions?.[0]
  const templateCount = templates?.length ?? 0
  const newTemplatePath = workspaceTemplateNewPath(workspaceUri)

  return (
    <section className={`${card} p-5`} aria-labelledby="recommended-title">
      <p className={sectionTitle}>推荐下一步</p>
      <h2 id="recommended-title" className="mt-1 text-lg font-semibold text-foreground">
        {continueSession ? `进入「${continueSession.name}」` : "开始你的工作"}
      </h2>
      <div className="mt-4 flex flex-wrap gap-2">
        {continueSession ? (
          <a
            className={primaryBtn}
            href={`/sessions?session=${encodeURIComponent(continueSession.uri)}`}
          >
            <ArrowRight className="h-4 w-4" />
            进入 Session
          </a>
        ) : null}
        <a className={continueSession ? ghostBtn : primaryBtn} href="/identities/agents/new">
          <Plus className="h-4 w-4" />
          创建 Agent
        </a>
        <a className={ghostBtn} href="/sessions">
          <Activity className="h-4 w-4" />
          浏览 Sessions
        </a>
        <a className={ghostBtn} href={newTemplatePath} title={`${templateCount} templates available`}>
          <LayoutDashboard className="h-4 w-4" />
          新建 Template
        </a>
      </div>
    </section>
  )
}

function workspaceTemplateNewPath(workspaceUri?: string | null) {
  const name = workspaceNameFromUri(workspaceUri) || "system"
  return `/workspaces/${encodeURIComponent(name)}/templates/new`
}

function workspaceNameFromUri(workspaceUri?: string | null) {
  if (!workspaceUri?.startsWith("workspace://")) return null
  return workspaceUri.replace("workspace://", "").split("/")[0] || null
}

// ── Section 2: Key Status (upgraded KPI with product labels) ───────
function KeyStatus({kpis}: {kpis: Record<string, number>}) {
  const items = [
    {key: "agents", label: "Agents", icon: <Route className="h-4 w-4" />},
    {key: "sessions", label: "Sessions", icon: <Activity className="h-4 w-4" />},
    {key: "workspaces", label: "Workspaces", icon: <Database className="h-4 w-4" />},
    {key: "entities", label: "实体", icon: <ShieldCheck className="h-4 w-4" />},
    {key: "kinds", label: "Kinds", icon: <Users className="h-4 w-4" />},
  ]

  return (
    <section className={`${card} p-5`} aria-labelledby="status-title">
      <p className={sectionTitle}>关键状态</p>
      <h2 id="status-title" className="sr-only">工作区关键指标</h2>
      <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        {items.map((item) => (
          <div key={item.key} className="rounded-md border border-border bg-background p-4">
            <div className={kpiIcon}>
              {item.icon}
              <span className="text-xs font-medium">{item.label}</span>
            </div>
            <p className="mt-2 text-2xl font-semibold text-foreground">{kpis[item.key] ?? 0}</p>
          </div>
        ))}
      </div>
    </section>
  )
}

// ── Section 3: Continue Sessions ───────────────────────────────────
function ContinueSessions({sessions}: {sessions?: Array<{uri: string; name: string}>}) {
  if (!sessions || sessions.length === 0) return null

  return (
    <section className={card} aria-labelledby="continue-title">
      <div className="flex items-center justify-between border-b border-border px-4 py-3">
        <h3 id="continue-title" className="text-sm font-semibold text-foreground">
          可继续的 Sessions
        </h3>
        <a className="text-xs text-primary hover:underline" href="/sessions">
          查看全部
        </a>
      </div>
      <div className="divide-y divide-border">
        {sessions.map((session) => (
          <div key={session.uri} className="flex items-center justify-between px-4 py-3">
            <div className="min-w-0">
              <p className="truncate text-sm font-medium text-foreground">{session.name}</p>
              <p className="truncate font-mono text-xs text-muted-foreground">{session.uri}</p>
            </div>
            <a
              className="shrink-0 text-xs text-primary hover:underline"
              href={`/sessions?session=${encodeURIComponent(session.uri)}`}
            >
              打开
            </a>
          </div>
        ))}
      </div>
    </section>
  )
}

// ── Main Overview ──────────────────────────────────────────────────
export function Overview({state}: {state?: OverviewState}) {
  const kpis = state?.kpis || {}

  return (
    <div className="space-y-6" data-world-component="overview">
      <RecommendedNext
        sessions={state?.available_sessions}
        templates={state?.session_template_names}
        workspaceUri={state?.workspace_uri}
      />
      <KeyStatus kpis={kpis} />
      <ContinueSessions sessions={state?.available_sessions} />
    </div>
  )
}
