import React from "react"
import {Activity, ArrowRight, Database, LayoutDashboard, Plus, Route, ShieldCheck, Users} from "lucide-react"

// Overview 操作员落地页（FP5 S2-a）。此前 `/` 与 `/sessions` 渲染同一个 sessions_table、
// 名实不符;现为独立 dashboard：KPI 概览（数据复用 AdminData，与 Admin Dashboard 同源）
// + 快捷入口。纯只读 + 导航，无 dispatch，自含不依赖 Admin.tsx 内部。

type OverviewState = {
  kpis?: Record<string, number>
  workspace_uri?: string | null
}

type Kpi = {label: string; key: string; icon: React.ReactNode}

const KPIS: Kpi[] = [
  {label: "会话", key: "sessions", icon: <Activity className="h-4 w-4" />},
  {label: "Agent", key: "agents", icon: <Route className="h-4 w-4" />},
  {label: "工作区", key: "workspaces", icon: <Database className="h-4 w-4" />},
  {label: "实体", key: "entities", icon: <ShieldCheck className="h-4 w-4" />},
  {label: "Kinds", key: "kinds", icon: <Database className="h-4 w-4" />},
]

type QuickLink = {label: string; href: string; icon: React.ReactNode; primary?: boolean}

const QUICK_LINKS: QuickLink[] = [
  {label: "新建会话", href: "/sessions", icon: <Plus className="h-4 w-4" />, primary: true},
  {label: "新建 Agent", href: "/identities/agents/new", icon: <Plus className="h-4 w-4" />, primary: true},
  {label: "会话", href: "/sessions", icon: <Activity className="h-4 w-4" />},
  {label: "身份", href: "/identities", icon: <Users className="h-4 w-4" />},
  {label: "管理后台", href: "/admin", icon: <LayoutDashboard className="h-4 w-4" />},
]

export function Overview({state}: {state?: OverviewState}) {
  const kpis = state?.kpis || {}

  return (
    <section
      className="space-y-6 rounded-lg border border-border bg-card p-5 text-card-foreground"
      aria-labelledby="overview-title"
      data-world-component="overview"
    >
      <div>
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">概览</p>
        <h2 id="overview-title" className="text-lg font-semibold text-foreground">
          工作区总览
        </h2>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        {KPIS.map((kpi) => (
          <div key={kpi.key} className="rounded-md border border-border bg-background p-4">
            <div className="flex items-center gap-2 text-muted-foreground">
              {kpi.icon}
              <span className="text-xs font-medium">{kpi.label}</span>
            </div>
            <p className="mt-2 text-2xl font-semibold text-foreground">{kpis[kpi.key] ?? 0}</p>
          </div>
        ))}
      </div>

      <div className="space-y-2">
        <h3 className="text-sm font-semibold text-foreground">快捷入口</h3>
        <div className="flex flex-wrap gap-2">
          {QUICK_LINKS.map((link) => (
            <a
              key={link.label}
              href={link.href}
              className={
                link.primary
                  ? "inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground transition hover:opacity-90"
                  : "inline-flex items-center gap-1.5 rounded-md border border-border px-3 py-1.5 text-sm font-medium text-muted-foreground transition hover:bg-muted hover:text-foreground"
              }
            >
              {link.icon}
              {link.label}
              {!link.primary && <ArrowRight className="h-3.5 w-3.5" aria-hidden="true" />}
            </a>
          ))}
        </div>
      </div>
    </section>
  )
}
