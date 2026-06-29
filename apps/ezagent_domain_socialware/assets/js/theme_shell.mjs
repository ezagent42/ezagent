// Hybrid architecture — the HAND-CRAFTED theme shell ("chrome").
//
// The beauty-vs-safety split: this file is HUMAN-authored React (so it can be as
// polished as we like — sticky glass nav, subtle themed backdrop, rich footer), and it
// is FIXED. The AI never writes here. The AI only authors the json-render BODY
// that drops into <Slot/>. "Change the look" = swap theme / tweak tokens (curated),
// never arbitrary AI code on a public page.
//
// React.createElement (no JSX) so it bundles under the viewer SPA's esbuild.
// Tailwind scans this file (viewer.css @source) → every literal class is built.
import React from "react"

const h = React.createElement
const str = (v) => (v == null ? "" : String(v))

const NAV_LINKS = [
  {label: "特性", href: "#features"},
  {label: "方案", href: "#pricing"},
  {label: "常见问题", href: "#faq"},
]
const FOOTER_COLS = [
  {title: "产品", links: ["特性", "方案", "更新日志", "路线图"]},
  {title: "公司", links: ["关于我们", "博客", "招聘", "联系"]},
  {title: "资源", links: ["文档", "API", "社区", "状态"]},
]

// ── The fixed, hand-crafted frame. `children` is the AI-authored json-render body.
export function PageShell({brand, children}) {
  const name = str(brand) || "Hello"
  return h(
    "div",
    {className: "relative min-h-screen w-full overflow-hidden bg-background text-foreground"},
    // decorative themed background (fixed, behind everything)
    h(
      "div",
      {className: "pointer-events-none fixed inset-0 -z-10", "aria-hidden": "true"},
      h("div", {className: "absolute -top-40 -left-20 h-[42rem] w-[42rem] rounded-full bg-primary/20 blur-[130px]"}),
      h("div", {className: "absolute top-1/4 -right-32 h-[40rem] w-[40rem] rounded-full bg-accent/20 blur-[130px]"}),
      h("div", {className: "absolute bottom-0 left-1/3 h-[34rem] w-[34rem] rounded-full bg-secondary/20 blur-[120px]"}),
      h("div", {className: "absolute inset-0 bg-[radial-gradient(circle_at_1px_1px,var(--border)_1px,transparent_0)] bg-[size:32px_32px] opacity-40"}),
    ),

    // ── sticky glass nav ──────────────────────────────────────────────────────
    h(
      "header",
      {className: "sticky top-0 z-50 w-full border-b border-border/60 bg-background/70 backdrop-blur-lg"},
      h(
        "nav",
        {className: "mx-auto flex h-16 max-w-6xl items-center justify-between px-6"},
        h(
          "a",
          {href: "#", className: "flex items-center gap-2"},
          h("span", {className: "flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-primary to-accent text-sm font-black text-primary-foreground shadow-md shadow-primary/30"}, name.slice(0, 1).toUpperCase()),
          h("span", {className: "bg-gradient-to-r from-primary to-accent bg-clip-text text-lg font-extrabold tracking-tight text-transparent"}, name),
        ),
        h(
          "div",
          {className: "hidden items-center gap-8 sm:flex"},
          NAV_LINKS.map((l) => h("a", {key: l.href, href: l.href, className: "text-sm font-medium text-foreground/70 transition hover:text-foreground"}, l.label)),
        ),
        h("a", {href: "#", className: "inline-flex items-center rounded-lg bg-gradient-to-r from-primary to-accent px-4 py-2 text-sm font-semibold text-primary-foreground shadow-sm transition hover:opacity-90"}, "开始使用"),
      ),
    ),

    // ── AI-authored body slot ─────────────────────────────────────────────────
    h("main", {className: "relative w-full"}, children),

    // ── hand-crafted footer ───────────────────────────────────────────────────
    h(
      "footer",
      {className: "w-full border-t border-border bg-[var(--neutral)] text-[var(--neutral-foreground)]"},
      h(
        "div",
        {className: "mx-auto max-w-6xl px-6 py-16"},
        h(
          "div",
          {className: "grid gap-10 sm:grid-cols-2 lg:grid-cols-4"},
          h(
            "div",
            {className: "space-y-3"},
            h(
              "div",
              {className: "flex items-center gap-2"},
              h("span", {className: "flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-primary to-accent text-sm font-black text-primary-foreground"}, name.slice(0, 1).toUpperCase()),
              h("span", {className: "text-lg font-extrabold tracking-tight"}, name),
            ),
            h("p", {className: "max-w-xs text-sm text-[color:var(--neutral-foreground)] opacity-60"}, name + " · 用一句话生成精美官网,内容由 AI 编排,框架稳定可靠。"),
          ),
          FOOTER_COLS.map((col) =>
            h(
              "div",
              {key: col.title, className: "space-y-3"},
              h("div", {className: "text-sm font-semibold"}, col.title),
              h(
                "ul",
                {className: "space-y-2"},
                col.links.map((lk) => h("li", {key: lk}, h("a", {href: "#", className: "text-sm text-[color:var(--neutral-foreground)] opacity-60 transition hover:opacity-100"}, lk))),
              ),
            ),
          ),
        ),
        h(
          "div",
          {className: "mt-12 flex flex-col items-center justify-between gap-3 border-t border-[color:color-mix(in_srgb,var(--neutral-foreground)_10%,transparent)] pt-6 text-sm text-[color:var(--neutral-foreground)] opacity-50 sm:flex-row"},
          h("span", {}, "© 2026 " + name + ". All rights reserved."),
          h(
            "div",
            {className: "flex gap-5"},
            h("a", {href: "#", className: "transition hover:opacity-100"}, "隐私"),
            h("a", {href: "#", className: "transition hover:opacity-100"}, "条款"),
          ),
        ),
      ),
    ),
  )
}
