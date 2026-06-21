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

export function Input({className, ...props}: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        "h-9 w-full rounded-md border border-slate-300 bg-white px-3 text-sm text-slate-950 shadow-sm outline-none transition focus:border-slate-500 focus:ring-2 focus:ring-slate-200 disabled:cursor-not-allowed disabled:opacity-50",
        className,
      )}
      {...props}
    />
  )
}

export function Textarea({className, ...props}: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      className={cn(
        "min-h-24 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none transition focus:border-slate-500 focus:ring-2 focus:ring-slate-200 disabled:cursor-not-allowed disabled:opacity-50",
        className,
      )}
      {...props}
    />
  )
}

export function Select({className, children, ...props}: React.SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select
      className={cn(
        "h-9 w-full rounded-md border border-slate-300 bg-white px-3 text-sm text-slate-950 shadow-sm outline-none transition focus:border-slate-500 focus:ring-2 focus:ring-slate-200 disabled:cursor-not-allowed disabled:opacity-50",
        className,
      )}
      {...props}
    >
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
    <section className={cn("rounded-md border border-slate-200 bg-white shadow-sm", className)}>
      {header && <div className="border-b border-slate-200 px-4 py-3 text-sm font-semibold text-slate-950">{header}</div>}
      <div className="p-4 text-sm text-slate-700">{children}</div>
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
  return <span className={cn("inline-flex items-center rounded-md border px-2 py-0.5 text-xs font-medium", toneClass(tone), className)}>{children}</span>
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
    <header className="flex items-end justify-between gap-4 border-b border-slate-200 pb-4">
      <div>
        <h1 className="text-xl font-semibold text-slate-950">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-slate-500">{subtitle}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </header>
  )
}

export function Breadcrumb({items}: {items: Array<{label: string; href?: string | null}>}) {
  return (
    <nav className="flex items-center gap-1 text-xs text-slate-500" aria-label="Breadcrumb">
      {items.map((item, index) => (
        <span className="inline-flex items-center gap-1" key={`${item.label}-${index}`}>
          {index > 0 && <ChevronRight aria-hidden="true" className="h-3 w-3" />}
          {item.href ? <a href={item.href}>{item.label}</a> : <span className="text-slate-900">{item.label}</span>}
        </span>
      ))}
    </nav>
  )
}

export function Stat({label, value, icon}: {label: string; value: React.ReactNode; icon?: React.ReactNode}) {
  return (
    <div className="rounded-md border border-slate-200 bg-white p-3">
      <div className="flex items-center gap-2 text-xs text-slate-500">
        {icon}
        <span>{label}</span>
      </div>
      <strong className="mt-1 block text-lg text-slate-950">{value}</strong>
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
      <strong className="text-slate-950">{name}</strong>
      {description && <p className="mt-2 text-slate-600">{description}</p>}
      {meta && <div className="mt-3 flex items-center gap-2 text-xs text-slate-500">{meta}</div>}
    </Card>
  )
}

export function StatusDot({tone = "default", pulse = false}: {tone?: Tone; pulse?: boolean}) {
  return <span className={cn("inline-block h-2 w-2 rounded-full", dotClass(tone), pulse && "animate-pulse")} />
}

export function Avatar({uri, size = "sm"}: {uri?: string | null; size?: "xs" | "sm" | "md"}) {
  const seed = uri || "?"
  const label = seed.split("/").filter(Boolean).pop()?.slice(0, 1).toUpperCase() || "?"
  const hue = hashHue(seed)
  const sizeClass = size === "md" ? "h-8 w-8 text-xs" : size === "xs" ? "h-4 w-4 text-[8px]" : "h-6 w-6 text-[10px]"

  return (
    <span
      className={cn("inline-flex shrink-0 items-center justify-center rounded-full font-medium text-white", sizeClass)}
      style={{background: `conic-gradient(from 220deg, hsl(${hue} 70% 52%), hsl(${(hue + 120) % 360} 65% 45%))`}}
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
    <div className="flex items-center gap-px border-b border-slate-200 bg-slate-50">
      {items.map((item) => {
        const active = item.key === selected
        return (
          <a
            className={cn(
              "border-b-2 px-3 py-1.5 text-xs font-medium transition",
              active ? "border-slate-950 bg-white text-slate-950" : "border-transparent text-slate-500 hover:bg-slate-100 hover:text-slate-700",
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
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/40">
      <section className="w-full max-w-md overflow-hidden rounded-md bg-white shadow-2xl">
        {title && <header className="border-b border-slate-200 px-4 py-3 text-sm font-semibold">{title}</header>}
        <div className="px-4 py-3 text-sm">{children}</div>
        {footer && <footer className="flex justify-end gap-2 border-t border-slate-200 bg-slate-50 px-4 py-3">{footer}</footer>}
      </section>
    </div>
  )
}

export function Toast({tone = "info", children}: {tone?: Tone; children: React.ReactNode}) {
  return <div className={cn("rounded-md border px-3 py-2 text-sm shadow-lg", toneClass(tone))}>{children}</div>
}

export function TreeList({items}: {items: Array<{id: string; label: React.ReactNode; depth?: number}>}) {
  return (
    <div className="rounded-md border border-slate-200 bg-white py-1 text-sm">
      {items.map((item) => (
        <div className="flex items-center gap-2 px-2 py-1.5" key={item.id} style={{paddingLeft: `${8 + (item.depth || 0) * 16}px`}}>
          <Circle aria-hidden="true" className="h-2 w-2 fill-slate-300 text-slate-300" />
          {item.label}
        </div>
      ))}
    </div>
  )
}

export function EmptyState({label, action}: {label: string; action?: React.ReactNode}) {
  return (
    <div className="rounded-md border border-dashed border-slate-300 bg-slate-50 px-4 py-6 text-center text-sm text-slate-500">
      <p>{label}</p>
      {action && <div className="mt-3">{action}</div>}
    </div>
  )
}

export function FormField({label, children}: {label: string; children: React.ReactNode}) {
  return (
    <label className="grid gap-1 text-xs text-slate-500">
      <span>{label}</span>
      {children}
    </label>
  )
}

export function UriChip({uri}: {uri?: string | null}) {
  return <code className="rounded-md border border-slate-200 bg-slate-50 px-2 py-0.5 text-xs text-slate-700">{uri || "none"}</code>
}

export function Toolbar({children}: {children: React.ReactNode}) {
  return <div className="flex items-center gap-2 border-b border-slate-200 bg-white px-3 py-2">{children}</div>
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
  if (tone === "primary") return "border-slate-950 bg-slate-950 text-white"
  if (tone === "success") return "border-emerald-200 bg-emerald-50 text-emerald-700"
  if (tone === "warning") return "border-amber-200 bg-amber-50 text-amber-700"
  if (tone === "danger") return "border-red-200 bg-red-50 text-red-700"
  if (tone === "info") return "border-sky-200 bg-sky-50 text-sky-700"
  return "border-slate-200 bg-slate-100 text-slate-700"
}

function dotClass(tone: Tone) {
  if (tone === "success") return "bg-emerald-500"
  if (tone === "warning") return "bg-amber-500"
  if (tone === "danger") return "bg-red-500"
  if (tone === "info") return "bg-sky-500"
  if (tone === "primary") return "bg-slate-950"
  return "bg-slate-400"
}

function hashHue(seed: string) {
  return Array.from(seed).reduce((acc, char) => (acc * 31 + char.charCodeAt(0)) % 360, 0)
}
