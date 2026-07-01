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
}: {
  sessions?: Array<{uri: string; name: string}>
  templates?: string[]
}) {
  const continueSession = sessions?.[0]
  const templateCount = templates?.length ?? 0

  return (
    <section className={`${card} p-5`} aria-labelledby="recommended-title">
      <p className={sectionTitle}>推荐下一步</p>
      <h2 id="recommended-title" className="mt-1 text-lg font-semibold text-foreground">
        {continueSession ? `继续「${continueSession.name}」` : "开始你的工作"}
      </h2>
      <p className="mt-1 text-sm text-muted-foreground">
        {continueSession
          ? "从已有会话继续，或创建新 Agent 挂入协作。"
          : "当前没有活跃会话，选择一个模板快速开始。"}
      </p>
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
        {templateCount > 0 ? (
          <a className={ghostBtn} href="/sessions">
            <LayoutDashboard className="h-4 w-4" />
            新建 Session ({templateCount} 模板)
          </a>
        ) : null}
      </div>
    </section>
  )
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
      <RecommendedNext sessions={state?.available_sessions} templates={state?.session_template_names} />
      <KeyStatus kpis={kpis} />
      <ContinueSessions sessions={state?.available_sessions} />
    </div>
  )
}
