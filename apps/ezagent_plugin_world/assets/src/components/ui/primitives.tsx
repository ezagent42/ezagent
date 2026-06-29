import type React from "react"
import {
  AlertCircle,
  CheckCircle2,
  ChevronRight,
  Circle,
  Info,
  Search,
  TerminalSquare,
  XCircle,
  type LucideIcon,
} from "lucide-react"

import {cn} from "../../lib/utils"
import {Button} from "./button"

export {Button}

// The atom names the ezagent_domain_ui layer expects to find here
// (primitive_coverage_test asserts each appears as a string). Keep in lockstep
// with the Elixir atom layer — preserve the list until the test swaps to a
// registry comparison (PR-3 keeps the string list; the swap is a later step).
export const domainUiPrimitiveCoverage = [
  "button",
  "input",
  "card",
  "badge",
  "page_header",
  "breadcrumb",
  "stat",
  "plugin_card",
  "flash_group",
  "status_dot",
  "avatar",
  "tabs",
  "modal",
  "toast",
  "tree_list",
  "empty_state",
  "form_field",
  "uri_chip",
  "toolbar",
  "tooltip",
  "icon",
  "uri_picker",
  "workspace_shell",
  "activity_bar",
  "status_bar",
  "admin_shell",
  "sidebar_nav",
  "ide_shell_outer",
  "editor_tabs",
  "split_pane",
  "command_palette",
  "pty_terminal",
  "routing_view",
  "external_mirror_view",
] as const

type Tone = "default" | "primary" | "success" | "warning" | "danger" | "info"

// Shared field styling — shadcn token-based, dark-aware (PR-3).
const fieldClass =
  "w-full rounded-full border border-input bg-card px-3 text-sm text-foreground shadow-sm outline-none transition focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40 disabled:cursor-not-allowed disabled:opacity-50"

export function Input({className, ...props}: React.InputHTMLAttributes<HTMLInputElement>) {
  return <input className={cn(fieldClass, "h-9", className)} {...props} />
}

export function Textarea({className, ...props}: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className={cn(fieldClass, "min-h-24 py-2", className)} {...props} />
}

export function Select({className, children, ...props}: React.SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select className={cn(fieldClass, "h-9", className)} {...props}>
      {children}
    </select>
  )
}

export function Card({
  className,
  header,
  children,
}: {
  className?: string
  header?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <section className={cn("rounded-[var(--radius)] bg-card shadow-[var(--shadow-card)]", className)}>
      {header && <div className="border-b border-border px-4 py-3 text-sm font-semibold text-card-foreground">{header}</div>}
      <div className="p-4 text-sm text-card-foreground">{children}</div>
    </section>
  )
}

export function Badge({
  tone = "default",
  className,
  children,
}: {
  tone?: Tone
  className?: string
  children: React.ReactNode
}) {
  return <span className={cn("inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium", toneClass(tone), className)}>{children}</span>
}

export function PageHeader({
  title,
  subtitle,
  actions,
}: {
  title: string
  subtitle?: React.ReactNode
  actions?: React.ReactNode
}) {
  return (
    <header className="flex items-end justify-between gap-4 border-b border-border pb-4">
      <div>
        <h1 className="text-xl font-semibold text-foreground">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-muted-foreground">{subtitle}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </header>
  )
}

export function Breadcrumb({items}: {items: Array<{label: string; href?: string | null}>}) {
  return (
    <nav className="flex items-center gap-1 text-xs text-muted-foreground" aria-label="Breadcrumb">
      {items.map((item, index) => (
        <span className="inline-flex items-center gap-1" key={`${item.label}-${index}`}>
          {index > 0 && <ChevronRight aria-hidden="true" className="h-3 w-3" />}
          {item.href ? <a href={item.href}>{item.label}</a> : <span className="text-foreground">{item.label}</span>}
        </span>
      ))}
    </nav>
  )
}

export function Stat({label, value, icon}: {label: string; value: React.ReactNode; icon?: React.ReactNode}) {
  return (
    <div className="rounded-[var(--radius)] bg-card p-3 shadow-[var(--shadow-card)]">
      <div className="flex items-center gap-2 text-xs text-muted-foreground">
        {icon}
        <span>{label}</span>
      </div>
      <strong className="mt-1 block text-lg text-foreground">{value}</strong>
    </div>
  )
}

export function PluginCard({
  name,
  description,
  meta,
}: {
  name: string
  description?: React.ReactNode
  meta?: React.ReactNode
}) {
  return (
    <Card>
      <strong className="text-foreground">{name}</strong>
      {description && <p className="mt-2 text-muted-foreground">{description}</p>}
      {meta && <div className="mt-3 flex items-center gap-2 text-xs text-muted-foreground">{meta}</div>}
    </Card>
  )
}

export function StatusDot({tone = "default", pulse = false}: {tone?: Tone; pulse?: boolean}) {
  return <span className={cn("inline-block h-2 w-2 rounded-full", dotClass(tone), pulse && "animate-pulse")} />
}

export function Avatar({uri, size = "sm"}: {uri?: string | null; size?: "xs" | "sm" | "md"}) {
  const seed = uri || "?"
  const label = seed.split("/").filter(Boolean).pop()?.slice(0, 1).toUpperCase() || "?"
  const sizeClass = size === "md" ? "h-8 w-8 text-xs" : size === "xs" ? "h-4 w-4 text-[8px]" : "h-6 w-6 text-[10px]"

  return (
    <span
      className={cn("inline-flex shrink-0 items-center justify-center rounded-full bg-primary font-medium text-primary-foreground", sizeClass)}
    >
      {label}
    </span>
  )
}

export function Tabs({
  items,
  selected,
}: {
  items: Array<{key: string; label: string; href?: string}>
  selected: string
}) {
  return (
    <div className="flex items-center gap-px border-b border-border bg-muted/40">
      {items.map((item) => {
        const active = item.key === selected
        return (
          <a
            className={cn(
              "border-b-2 px-3 py-1.5 text-xs font-medium transition",
              active
                ? "border-foreground bg-background text-foreground"
                : "border-transparent text-muted-foreground hover:bg-muted hover:text-foreground",
            )}
            href={item.href || "#"}
            key={item.key}
          >
            {item.label}
          </a>
        )
      })}
    </div>
  )
}

export function Modal({open, title, children, footer}: {open: boolean; title?: string; children: React.ReactNode; footer?: React.ReactNode}) {
  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <section className="w-full max-w-md overflow-hidden rounded-[var(--radius)] bg-card text-card-foreground shadow-[var(--shadow-card)]">
        {title && <header className="border-b border-border px-4 py-3 text-sm font-semibold">{title}</header>}
        <div className="px-4 py-3 text-sm">{children}</div>
        {footer && <footer className="flex justify-end gap-2 border-t border-border bg-muted/40 px-4 py-3">{footer}</footer>}
      </section>
    </div>
  )
}

export function Toast({tone = "info", children}: {tone?: Tone; children: React.ReactNode}) {
  return <div className={cn("rounded-[var(--radius)] px-3 py-2 text-sm shadow-[var(--shadow-card)]", toneClass(tone))}>{children}</div>
}

export function TreeList({items}: {items: Array<{id: string; label: React.ReactNode; depth?: number}>}) {
  return (
    <div className="rounded-[var(--radius)] bg-card py-1 text-sm text-card-foreground shadow-[var(--shadow-card)]">
      {items.map((item) => (
        <div className="flex items-center gap-2 px-2 py-1.5" key={item.id} style={{paddingLeft: `${8 + (item.depth || 0) * 16}px`}}>
          <Circle aria-hidden="true" className="h-2 w-2 fill-muted-foreground/40 text-muted-foreground/40" />
          {item.label}
        </div>
      ))}
    </div>
  )
}

export function EmptyState({label, action}: {label: string; action?: React.ReactNode}) {
  return (
    <div className="rounded-[var(--radius)] border border-dashed border-border bg-muted/40 px-4 py-6 text-center text-sm text-muted-foreground">
      <p>{label}</p>
      {action && <div className="mt-3">{action}</div>}
    </div>
  )
}

export function FormField({label, children}: {label: string; children: React.ReactNode}) {
  return (
    <label className="grid gap-1 text-xs text-muted-foreground">
      <span>{label}</span>
      {children}
    </label>
  )
}

export function UriChip({uri}: {uri?: string | null}) {
  return <code className="rounded-full border border-border bg-muted/50 px-2 py-0.5 text-xs text-muted-foreground">{uri || "none"}</code>
}

export function Toolbar({children}: {children: React.ReactNode}) {
  return <div className="flex items-center gap-2 border-b border-border bg-card px-3 py-2">{children}</div>
}

export function Tooltip({label, children}: {label: string; children: React.ReactNode}) {
  return (
    <span className="inline-flex" title={label}>
      {children}
    </span>
  )
}

export function Icon({name = "info", className}: {name?: "info" | "success" | "danger" | "search" | "terminal"; className?: string}) {
  const icons: Record<string, LucideIcon> = {
    danger: XCircle,
    info: Info,
    search: Search,
    success: CheckCircle2,
    terminal: TerminalSquare,
  }
  const Component = icons[name] || AlertCircle
  return <Component aria-hidden="true" className={cn("h-4 w-4", className)} />
}

export function UriPicker({options = [], value}: {options?: string[]; value?: string | string[]}) {
  const selected = Array.isArray(value) ? value : value ? [value] : []

  return (
    <div className="grid gap-2">
      <div className="flex flex-wrap gap-1">
        {selected.map((uri) => (
          <UriChip key={uri} uri={uri} />
        ))}
      </div>
      <Select defaultValue={selected[0] || ""}>
        <option value="">Select URI</option>
        {options.map((uri) => (
          <option key={uri} value={uri}>
            {uri}
          </option>
        ))}
      </Select>
    </div>
  )
}

function toneClass(tone: Tone) {
  if (tone === "primary") return "border-transparent bg-primary text-primary-foreground"
  if (tone === "success") return "border-transparent bg-[color:color-mix(in_srgb,var(--ez-jade)_12%,white)] text-[var(--ez-jade)]"
  if (tone === "warning") return "border-transparent bg-accent text-accent-foreground"
  if (tone === "danger") return "border-transparent bg-destructive/10 text-destructive"
  if (tone === "info") return "border-transparent bg-[color:color-mix(in_srgb,var(--ez-blueink)_10%,white)] text-[var(--ez-blueink)]"
  return "border-transparent bg-muted text-muted-foreground"
}

function dotClass(tone: Tone) {
  if (tone === "success") return "bg-[var(--ez-jade)]"
  if (tone === "warning") return "bg-[var(--ez-yellow)]"
  if (tone === "danger") return "bg-destructive"
  if (tone === "info") return "bg-[var(--ez-blueink)]"
  if (tone === "primary") return "bg-primary"
  return "bg-muted-foreground/50"
}
