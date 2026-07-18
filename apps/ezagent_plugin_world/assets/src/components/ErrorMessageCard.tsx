import type React from "react"
import {AlertCircle, X} from "lucide-react"
import {cn} from "../lib/utils"
import {categoryTone, type RenderedError} from "../lib/errorRenderer"

type ErrorMessageCardProps = {
  error: RenderedError
  onDismiss?: () => void
  onAction?: (action: string, args?: Record<string, unknown>) => void
  onNavigate?: (href: string) => void
}

export function ErrorMessageCard({error, onDismiss, onAction, onNavigate}: ErrorMessageCardProps) {
  const tone = categoryTone(error.category)

  // 浮动 toast 必须不透明:背景用实心 bg-card,tone 只体现在边框和图标上
  // （半透明色调浮在页面上方时,底下的内容会透过来）。
  const borderClass =
    tone === "danger"
      ? "border-destructive/40 bg-card"
      : tone === "warning"
        ? "border-amber-500/40 bg-card"
        : "border-[var(--ez-blueink)]/40 bg-card"

  const iconClass =
    tone === "danger"
      ? "text-destructive"
      : tone === "warning"
        ? "text-amber-500"
        : "text-[var(--ez-blueink)]"

  return (
    <div
      role="alert"
      aria-live="polite"
      data-error-code={error.code}
      data-error-layer={error.layer}
      className={cn(
        "relative rounded-[var(--radius)] border p-3.5 text-sm shadow-[var(--shadow-card)]",
        borderClass,
      )}
    >
      <div className="flex items-start gap-3">
        <span className={cn("mt-0.5 shrink-0", iconClass)}>
          <AlertCircle aria-hidden="true" className="h-4 w-4" />
        </span>
        <div className="min-w-0 flex-1">
          <p className="font-medium text-foreground">{error.what}</p>
          <p className="mt-1 text-muted-foreground">{error.impact}</p>
          {error.detail && (
            <p className="mt-1.5 break-all font-mono text-xs text-muted-foreground/80" data-error-detail>
              {error.detail}
            </p>
          )}
          {(error.primaryAction || error.secondaryAction) && (
            <div className="mt-2.5 flex flex-wrap items-center gap-2">
              {error.primaryAction && (
                <button
                  type="button"
                  onClick={() => {
                    if (error.primaryAction?.href) {
                      onNavigate?.(error.primaryAction.href)
                    } else if (error.primaryAction?.action) {
                      onAction?.(error.primaryAction.action, error.primaryAction.args)
                    }
                  }}
                  className="inline-flex items-center rounded-md bg-primary px-2.5 py-1 text-xs font-medium text-primary-foreground hover:opacity-90"
                >
                  {error.primaryAction.label}
                </button>
              )}
              {error.secondaryAction && (
                <button
                  type="button"
                  onClick={() => {
                    if (error.secondaryAction?.action) {
                      onAction?.(error.secondaryAction.action, error.secondaryAction.args)
                    }
                  }}
                  className="inline-flex items-center rounded-md border border-border bg-card px-2.5 py-1 text-xs font-medium text-foreground hover:bg-muted"
                >
                  {error.secondaryAction.label}
                </button>
              )}
            </div>
          )}
          {error.layer === 3 && (
            <p className="mt-2 text-xs text-muted-foreground">此问题已自动登记，系统管理员会处理。</p>
          )}
        </div>
        {onDismiss && (
          <button
            type="button"
            onClick={onDismiss}
            aria-label="关闭"
            className="-mr-1 -mt-1 rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
          >
            <X aria-hidden="true" className="h-4 w-4" />
          </button>
        )}
      </div>
    </div>
  )
}
