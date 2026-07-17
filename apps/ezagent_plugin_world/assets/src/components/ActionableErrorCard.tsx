import React from "react"
import {AlertTriangle, ArrowUpRight} from "lucide-react"

export type ActionableError = {
  code: string
  severity?: "error" | "warning"
  layer?: number
  title: string
  what_happened: string
  impact: string
  next_step: string
  action?: {
    label: string
    href?: string | null
  }
  detail?: string | null
  ticket?: string | null
}

const layerLabel = (layer?: number) => {
  if (layer === 1) return "可自行处理"
  if (layer === 2) return "需要管理员"
  return "需要排查"
}

export function ActionableErrorCard({error}: {error: ActionableError}) {
  const warning = error.severity === "warning"

  return (
    <section
      role="alert"
      aria-labelledby={`actionable-error-${error.code}`}
      className={warning
        ? "mt-1 overflow-hidden rounded-lg border border-amber-500/30 bg-amber-50/80 text-foreground shadow-sm"
        : "mt-1 overflow-hidden rounded-lg border border-destructive/30 bg-destructive/5 text-foreground shadow-sm"
      }
      data-actionable-error
      data-error-code={error.code}
    >
      <div className={warning ? "h-1 bg-amber-500" : "h-1 bg-destructive"} />
      <div className="space-y-3 p-3.5">
        <header className="flex items-start gap-2.5">
          <span className={warning ? "mt-0.5 rounded-md bg-amber-100 p-1.5 text-amber-700" : "mt-0.5 rounded-md bg-destructive/10 p-1.5 text-destructive"}>
            <AlertTriangle aria-hidden="true" className="h-4 w-4" />
          </span>
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="text-[10px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">故障处置</span>
              <span className="rounded-full border border-border bg-card px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground">{layerLabel(error.layer)}</span>
            </div>
            <h3 id={`actionable-error-${error.code}`} className="mt-1 text-[13.5px] font-semibold leading-snug text-foreground">{error.title}</h3>
          </div>
          <code className="shrink-0 rounded bg-foreground/[0.06] px-1.5 py-1 font-mono text-[10px] text-muted-foreground">{error.code}</code>
        </header>

        <dl className="grid gap-2.5 text-[12.5px] leading-relaxed">
          <div>
            <dt className="font-semibold text-foreground">发生了什么</dt>
            <dd className="mt-0.5 text-muted-foreground">{error.what_happened}</dd>
          </div>
          <div>
            <dt className="font-semibold text-foreground">影响</dt>
            <dd className="mt-0.5 text-muted-foreground">{error.impact}</dd>
          </div>
          <div>
            <dt className="font-semibold text-foreground">下一步</dt>
            <dd className="mt-0.5 text-muted-foreground">{error.next_step}</dd>
          </div>
        </dl>

        {(error.detail || error.ticket) && (
          <div className="flex flex-wrap gap-x-3 gap-y-1 border-t border-border/70 pt-2 font-mono text-[10.5px] text-muted-foreground">
            {error.ticket && <span>工单 {error.ticket}</span>}
            {error.detail && <span className="break-all">诊断 {error.detail}</span>}
          </div>
        )}

        {error.action?.href && (
          <a
            href={error.action.href}
            className="inline-flex items-center gap-1.5 rounded-md bg-foreground px-2.5 py-1.5 text-[11.5px] font-semibold text-background transition-opacity hover:opacity-85 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            {error.action.label}
            <ArrowUpRight aria-hidden="true" className="h-3.5 w-3.5" />
          </a>
        )}
      </div>
    </section>
  )
}
