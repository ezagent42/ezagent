// The customer-surface page renderer, built on the REAL Vercel `@json-render`.
// A rich "block library" (not a flat catalog): full-bleed sections with tone
// variants, real inline-SVG icons, and ~25 designed marketing blocks, so an
// AI-authored page reads like a real official site rather than a template.
//
// Written with `React.createElement` (no JSX) so it bundles under the customer
// SPA's esbuild without a JSX-runtime pragma. Tailwind scans THIS file
// (customer.css @source), so every literal class below is generated.
import React from "react"
import {Renderer, JSONUIProvider, defineRegistry} from "@json-render/react"
import {schema} from "@json-render/react/schema"
import {defineCatalog, nestedToFlat} from "@json-render/core"
import {z} from "zod"

const h = React.createElement
const opt = z.string().nullable().optional()
const optNum = z.union([z.number(), z.string()]).nullable().optional()
const str = (v) => (v == null ? "" : String(v))

// Coherent AI styling: every component root gets a SEMANTIC class `hl-<type>`
// (hl-hero, hl-feature, …) that the AI-authored shell themes via a <style> block,
// so the WHOLE page — frame AND content — shares one design the model authored
// (it's good at cohesive CSS). Plus any per-node `class` prop (Tailwind) the model
// adds. Both layer on top of the built-in defaults; safe (pure CSS).
function withClass(fn, key) {
  return (args) => {
    const el = fn(args)
    if (!el || !el.props) return el
    const semantic = key ? "hl-" + key : ""
    const extra = (args && args.props && args.props.class) || ""
    const merged = ((el.props.className || "") + " " + semantic + " " + extra)
      .replace(/\s+/g, " ")
      .trim()
    return React.cloneElement(el, {className: merged})
  }
}
const applyClass = (components) =>
  Object.fromEntries(Object.entries(components).map(([k, fn]) => [k, withClass(fn, k)]))

// ── Inline SVG icon set (stroke, currentColor) ───────────────────────────────
const ICON_PATHS = {
  check: "M20 6 9 17l-5-5",
  bolt: "M13 2 4 14h6l-1 8 9-12h-6l1-8z",
  zap: "M13 2 4 14h6l-1 8 9-12h-6l1-8z",
  shield: "M12 2 4 5v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V5l-8-3z",
  star: "M12 2l3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1z",
  lock: "M5 11h14v10H5zM8 11V7a4 4 0 0 1 8 0v4",
  globe: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zM2 12h20M12 2c3 3 3 17 0 20M12 2c-3 3-3 17 0 20",
  chart: "M3 20h18M6 20v-6M11 20V8M16 20v-10",
  users: "M16 20v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 10a3 3 0 1 0 0-6 3 3 0 0 0 0 6M22 20v-2a4 4 0 0 0-3-3.8M16 4.2A3 3 0 0 1 16 10",
  heart: "M12 21s-7-4.5-9-9a4.5 4.5 0 0 1 9-2 4.5 4.5 0 0 1 9 2c-2 4.5-9 9-9 9z",
  sparkles: "M12 3l2 5 5 2-5 2-2 5-2-5-5-2 5-2z",
  gauge: "M12 14l4-4M3 13a9 9 0 0 1 18 0",
  cloud: "M6 18a4 4 0 0 1 0-8 5 5 0 0 1 9.6-1.5A3.5 3.5 0 0 1 18 18z",
  rocket: "M5 13c-1.5 1.5-2 5-2 5s3.5-.5 5-2M9 11a8 8 0 0 1 8-8c1 0 2 .2 2 .2s.2 1 .2 2a8 8 0 0 1-8 8M9 11l4 4M15 9a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3",
  code: "M16 18l6-6-6-6M8 6l-6 6 6 6",
  layers: "M12 2 2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5",
  clock: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zM12 7v5l3 2",
}
function Icon({name, className}) {
  const d = ICON_PATHS[name] || ICON_PATHS.sparkles
  return h(
    "svg",
    {className: className || "h-6 w-6", viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: "2", strokeLinecap: "round", strokeLinejoin: "round", "aria-hidden": "true"},
    h("path", {d}),
  )
}

// ── Tone (full-bleed section background) variants ────────────────────────────
// `default` is TRANSPARENT so the hand-authored HTML shell's decorative
// background (gradients / orbs / mesh) shows THROUGH the json-render content —
// the content "floats" on the atmosphere rather than covering it with opaque
// blocks. Explicit tones still paint a band when the page wants contrast.
const TONE = {
  default: "text-base-content",
  muted: "bg-base-200/50 text-base-content backdrop-blur-sm",
  dark: "bg-neutral text-neutral-content",
  brand: "bg-gradient-to-br from-primary via-primary to-accent text-primary-content",
}
const toneClass = (t) => TONE[t] || TONE.default
// A full-width section band with a centered inner content column. max-w-6xl so
// content fills more of a wide monitor (max-w-5xl read as a thin strip).
const band = (tone, extra, inner) =>
  h("section", {className: `w-full px-6 py-16 sm:py-24 ${toneClass(tone)} ${extra || ""}`}, h("div", {className: "mx-auto max-w-6xl"}, inner))
const eyebrow = (text) =>
  text ? h("p", {className: "mb-3 text-center text-sm font-semibold uppercase tracking-widest text-primary"}, str(text)) : null

const clampLevel = (v) => {
  const n = Number(v)
  return Number.isFinite(n) ? Math.min(6, Math.max(1, Math.trunc(n))) : 2
}
const HEADING_CLASS = {
  1: "text-4xl sm:text-5xl font-bold tracking-tight",
  2: "text-2xl sm:text-3xl font-bold tracking-tight",
  3: "text-xl font-semibold",
  4: "text-lg font-semibold",
  5: "text-base font-semibold",
  6: "text-sm font-semibold uppercase tracking-wide opacity-60",
}

// ── Catalog (schema) — MUST stay in sync with EzagentPluginHello.Spec.catalog ─
const catalog = defineCatalog(schema, {
  components: {
    page: {props: z.object({class: opt,title: opt}), description: "Page root: a full-width vertical stack of blocks. Title is metadata (not rendered as a banner)."},
    nav: {props: z.object({class: opt,brand: opt}), description: "Top navigation bar: a brand name + child `button` links."},
    banner: {props: z.object({class: opt,text: opt}), description: "A thin full-width announcement banner at the very top."},
    hero: {props: z.object({class: opt,title: opt, subtitle: opt, cta_label: opt, cta_href: opt, badge: opt}), description: "Big brand-gradient hero: optional badge + title + subtitle + CTA. Use ONE, first."},
    section: {props: z.object({class: opt,layout: opt, tone: opt, title: opt}), description: "Generic section; layout 'stack'|'grid'; tone 'default'|'muted'|'dark'|'brand'."},
    card: {props: z.object({class: opt,title: opt}), description: "A titled card wrapping its children."},
    heading: {props: z.object({class: opt,text: opt, level: optNum}), description: "A heading; level 1–6."},
    text: {props: z.object({class: opt,text: opt}), description: "A paragraph of text."},
    button: {props: z.object({class: opt,label: opt, href: opt}), description: "A link/button."},
    image: {props: z.object({class: opt,src: opt, alt: opt}), description: "An image (renders a tasteful placeholder when the src can't load)."},
    features: {props: z.object({class: opt,title: opt, subtitle: opt, tone: opt}), description: "A features section: title/subtitle + a grid of `feature` children."},
    feature: {props: z.object({class: opt,title: opt, text: opt, icon: opt}), description: "One feature card; icon is a name like shield/zap/rocket/lock/globe/chart/users/cloud/code/gauge/star/check."},
    split: {props: z.object({class: opt,title: opt, text: opt, cta_label: opt, cta_href: opt, reverse: opt, icon: opt, tone: opt}), description: "A text+visual row; set reverse 'true' to flip sides. Alternate reverse for rhythm."},
    stats: {props: z.object({class: opt,title: opt, tone: opt}), description: "A row of metrics; children are `stat`."},
    stat: {props: z.object({class: opt,value: opt, label: opt}), description: "One metric: a big value + a label."},
    testimonials: {props: z.object({class: opt,title: opt, tone: opt}), description: "A testimonials section; children are `testimonial`."},
    testimonial: {props: z.object({class: opt,quote: opt, author: opt, role: opt}), description: "One customer quote + author + role."},
    logos: {props: z.object({class: opt,title: opt, tone: opt}), description: "A trusted-by logo wall; children are `logo`."},
    logo: {props: z.object({class: opt,name: opt}), description: "One brand chip (renders the name)."},
    pricing: {props: z.object({class: opt,title: opt, subtitle: opt, tone: opt}), description: "A pricing section; children are `plan`."},
    plan: {props: z.object({class: opt,name: opt, price: opt, period: opt, cta_label: opt, featured: opt}), description: "One pricing tier; child `text`/`feature` nodes list what's included; featured 'true' highlights it."},
    faq: {props: z.object({class: opt,title: opt, tone: opt}), description: "An FAQ accordion; children are `qa`."},
    qa: {props: z.object({class: opt,question: opt, answer: opt}), description: "One expandable question + answer."},
    steps: {props: z.object({class: opt,title: opt, tone: opt}), description: "A numbered process/timeline; children are `step`."},
    step: {props: z.object({class: opt,title: opt, text: opt}), description: "One numbered step."},
    cta: {props: z.object({class: opt,title: opt, text: opt, button_label: opt, button_href: opt, tone: opt}), description: "A closing call-to-action band. Use near the bottom."},
    footer: {props: z.object({class: opt,text: opt}), description: "A dark page footer."},
  },
  actions: {},
})

// ── Registry (implementations) ───────────────────────────────────────────────
const {registry} = defineRegistry(catalog, {
  components: applyClass({
    page: ({children}) => h("div", {className: "w-full"}, children),

    nav: ({props, children}) =>
      h(
        "nav",
        {className: "w-full border-b border-base-300 bg-base-100/80 px-6 py-4 backdrop-blur"},
        h(
          "div",
          {className: "mx-auto flex max-w-5xl items-center justify-between"},
          h("span", {className: "text-lg font-extrabold tracking-tight text-base-content"}, str(props.brand) || "Brand"),
          h("div", {className: "flex items-center gap-2"}, children),
        ),
      ),

    banner: ({props}) =>
      h(
        "div",
        {className: "w-full bg-gradient-to-r from-primary to-accent px-6 py-2 text-center text-sm font-medium text-primary-content"},
        str(props.text),
      ),

    hero: ({props}) =>
      h(
        "section",
        {className: "relative w-full overflow-hidden bg-gradient-to-br from-primary via-primary to-accent px-6 py-24 text-center text-primary-content sm:py-32"},
        h("div", {className: "pointer-events-none absolute -right-24 -top-24 h-72 w-72 rounded-full bg-base-100/10 blur-3xl"}),
        h("div", {className: "pointer-events-none absolute -bottom-24 -left-24 h-72 w-72 rounded-full bg-accent/30 blur-3xl"}),
        h(
          "div",
          {className: "relative mx-auto max-w-3xl space-y-6"},
          props.badge ? h("span", {className: "inline-block rounded-full border border-primary-content/30 bg-primary-content/10 px-4 py-1 text-sm font-medium"}, str(props.badge)) : null,
          props.title ? h("h1", {className: "text-4xl font-extrabold tracking-tight drop-shadow-sm sm:text-6xl"}, str(props.title)) : null,
          props.subtitle ? h("p", {className: "mx-auto max-w-2xl text-lg leading-8 text-primary-content/85 sm:text-xl"}, str(props.subtitle)) : null,
          props.cta_label
            ? h("div", {className: "pt-2"}, h("a", {className: "inline-flex items-center justify-center rounded-xl bg-base-100 px-8 py-3.5 text-base font-bold text-primary shadow-lg transition hover:scale-105 hover:shadow-xl", href: str(props.cta_href) || "#"}, str(props.cta_label)))
            : null,
        ),
      ),

    section: ({props, children}) =>
      band(
        props.tone,
        "",
        h(
          "div",
          {className: "space-y-6"},
          props.title ? h("h2", {className: "text-center text-2xl font-bold tracking-tight sm:text-3xl"}, str(props.title)) : null,
          props.layout === "grid"
            ? h("div", {className: "grid gap-6 sm:grid-cols-2 lg:grid-cols-3"}, children)
            : h("div", {className: "space-y-6"}, children),
        ),
      ),

    card: ({props, children}) =>
      h(
        "div",
        {className: "rounded-2xl border border-base-300/60 bg-base-100/70 backdrop-blur-xl p-6 shadow-sm transition hover:shadow-md"},
        props.title ? h("h3", {className: "text-lg font-semibold"}, str(props.title)) : null,
        h("div", {className: "mt-2 space-y-3"}, children),
      ),

    heading: ({props}) => {
      const lvl = clampLevel(props.level)
      return h("h" + lvl, {className: HEADING_CLASS[lvl]}, str(props.text))
    },
    text: ({props}) => h("p", {className: "max-w-prose text-base leading-7 opacity-70"}, str(props.text)),
    button: ({props}) => {
      const cls = "inline-flex items-center justify-center rounded-lg bg-primary px-5 py-2.5 text-sm font-semibold text-primary-content shadow-sm transition hover:opacity-90"
      return props.href ? h("a", {className: cls, href: str(props.href)}, str(props.label)) : h("button", {className: cls, type: "button"}, str(props.label))
    },
    image: ImageNode,

    features: ({props, children}) =>
      band(
        props.tone,
        "",
        h(
          "div",
          {className: "space-y-10"},
          h(
            "div",
            {className: "space-y-3 text-center"},
            eyebrow(props.subtitle ? "Features" : null),
            props.title ? h("h2", {className: "text-2xl font-bold tracking-tight sm:text-3xl"}, str(props.title)) : null,
            props.subtitle ? h("p", {className: "mx-auto max-w-2xl opacity-60"}, str(props.subtitle)) : null,
          ),
          h("div", {className: "grid gap-6 sm:grid-cols-2 lg:grid-cols-3"}, children),
        ),
      ),

    feature: ({props}) =>
      h(
        "div",
        {className: "group rounded-2xl border border-base-300/60 bg-base-100/70 backdrop-blur-xl p-6 text-base-content shadow-sm transition hover:-translate-y-1 hover:border-primary/40 hover:shadow-lg hover:shadow-primary/10"},
        h("div", {className: "mb-4 inline-flex h-12 w-12 items-center justify-center rounded-xl bg-gradient-to-br from-primary to-accent text-primary-content shadow-md shadow-primary/30"}, h(Icon, {name: str(props.icon), className: "h-6 w-6"})),
        props.title ? h("h3", {className: "text-lg font-bold"}, str(props.title)) : null,
        props.text ? h("p", {className: "mt-2 text-sm leading-6 opacity-60"}, str(props.text)) : null,
      ),

    split: ({props}) => {
      const reverse = str(props.reverse) === "true"
      const textCol = h(
        "div",
        {className: "flex-1 space-y-5"},
        h("div", {className: "inline-flex h-12 w-12 items-center justify-center rounded-xl bg-gradient-to-br from-primary to-accent text-primary-content shadow-md shadow-primary/30"}, h(Icon, {name: str(props.icon), className: "h-6 w-6"})),
        props.title ? h("h2", {className: "text-2xl font-bold tracking-tight sm:text-3xl"}, str(props.title)) : null,
        props.text ? h("p", {className: "text-base leading-7 opacity-70"}, str(props.text)) : null,
        props.cta_label ? h("a", {className: "inline-flex items-center gap-1 font-semibold text-primary hover:underline", href: str(props.cta_href) || "#"}, str(props.cta_label), " →") : null,
      )
      const visual = h(
        "div",
        {className: "flex aspect-[4/3] flex-1 items-center justify-center rounded-3xl bg-gradient-to-br from-primary/15 via-base-200 to-accent/15 shadow-inner"},
        h("div", {className: "flex h-16 w-16 items-center justify-center rounded-2xl bg-base-100/70 text-primary shadow-sm"}, h(Icon, {name: str(props.icon), className: "h-8 w-8"})),
      )
      return band(props.tone, "", h("div", {className: `flex flex-col items-center gap-10 sm:flex-row ${reverse ? "sm:flex-row-reverse" : ""}`}, textCol, visual))
    },

    stats: ({props, children}) =>
      band(
        props.tone || "muted",
        "",
        h(
          "div",
          {className: "space-y-8"},
          props.title ? h("h2", {className: "text-center text-2xl font-bold tracking-tight sm:text-3xl"}, str(props.title)) : null,
          h("div", {className: "grid grid-cols-2 gap-8 sm:grid-cols-4"}, children),
        ),
      ),
    stat: ({props}) =>
      h(
        "div",
        {className: "text-center"},
        h("div", {className: "bg-gradient-to-br from-primary to-accent bg-clip-text text-4xl font-extrabold tracking-tight text-transparent sm:text-5xl"}, str(props.value)),
        h("div", {className: "mt-1.5 text-sm font-medium opacity-60"}, str(props.label)),
      ),

    testimonials: ({props, children}) =>
      band(
        props.tone,
        "",
        h(
          "div",
          {className: "space-y-10"},
          props.title ? h("h2", {className: "text-center text-2xl font-bold tracking-tight sm:text-3xl"}, str(props.title)) : null,
          h("div", {className: "grid gap-6 sm:grid-cols-2 lg:grid-cols-3"}, children),
        ),
      ),
    testimonial: ({props}) =>
      h(
        "figure",
        {className: "flex h-full flex-col justify-between rounded-2xl border border-base-300/60 bg-base-100/70 backdrop-blur-xl p-6 text-base-content shadow-sm"},
        h("blockquote", {className: "text-base leading-7 opacity-80"}, "“", str(props.quote), "”"),
        h(
          "figcaption",
          {className: "mt-5 flex items-center gap-3"},
          h("div", {className: "flex h-10 w-10 items-center justify-center rounded-full bg-gradient-to-br from-primary to-accent text-sm font-bold text-primary-content"}, str(props.author).slice(0, 1) || "★"),
          h("div", {}, h("div", {className: "text-sm font-semibold"}, str(props.author)), h("div", {className: "text-xs opacity-50"}, str(props.role))),
        ),
      ),

    logos: ({props, children}) =>
      band(
        props.tone || "muted",
        "",
        h(
          "div",
          {className: "space-y-6 text-center"},
          props.title ? h("p", {className: "text-sm font-semibold uppercase tracking-widest opacity-50"}, str(props.title)) : null,
          h("div", {className: "flex flex-wrap items-center justify-center gap-4"}, children),
        ),
      ),
    logo: ({props}) => h("div", {className: "rounded-xl border border-base-300/60 bg-base-100/70 backdrop-blur-xl px-5 py-2.5 text-base font-bold text-base-content/70"}, str(props.name)),

    pricing: ({props, children}) =>
      band(
        props.tone,
        "",
        h(
          "div",
          {className: "space-y-10"},
          h(
            "div",
            {className: "space-y-3 text-center"},
            props.title ? h("h2", {className: "text-2xl font-bold tracking-tight sm:text-3xl"}, str(props.title)) : null,
            props.subtitle ? h("p", {className: "mx-auto max-w-2xl opacity-60"}, str(props.subtitle)) : null,
          ),
          h("div", {className: "grid gap-6 sm:grid-cols-3"}, children),
        ),
      ),
    plan: ({props, children}) => {
      const featured = str(props.featured) === "true"
      return h(
        "div",
        {className: `flex flex-col rounded-2xl border bg-base-100/70 backdrop-blur-xl p-6 text-base-content shadow-sm ${featured ? "border-primary ring-2 ring-primary/30 shadow-lg shadow-primary/10" : "border-base-300"}`},
        featured ? h("span", {className: "mb-3 inline-block w-fit rounded-full bg-primary px-3 py-1 text-xs font-semibold text-primary-content"}, "推荐") : null,
        h("h3", {className: "text-lg font-bold"}, str(props.name)),
        h("div", {className: "mt-2 flex items-end gap-1"}, h("span", {className: "text-4xl font-extrabold tracking-tight"}, str(props.price)), props.period ? h("span", {className: "pb-1 text-sm opacity-50"}, "/" + str(props.period)) : null),
        h("div", {className: "mt-5 flex-1 space-y-2 text-sm opacity-70"}, children),
        props.cta_label ? h("a", {className: `mt-6 inline-flex items-center justify-center rounded-lg px-5 py-2.5 text-sm font-semibold transition ${featured ? "bg-primary text-primary-content hover:opacity-90" : "border border-base-300 hover:bg-base-200"}`, href: "#"}, str(props.cta_label)) : null,
      )
    },

    faq: ({props, children}) =>
      band(
        props.tone,
        "",
        h(
          "div",
          {className: "mx-auto max-w-3xl space-y-4"},
          props.title ? h("h2", {className: "mb-8 text-center text-2xl font-bold tracking-tight sm:text-3xl"}, str(props.title)) : null,
          h("div", {className: "space-y-3"}, children),
        ),
      ),
    qa: ({props}) =>
      h(
        "details",
        {className: "group rounded-xl border border-base-300/60 bg-base-100/70 backdrop-blur-xl p-5 text-base-content [&_summary::-webkit-details-marker]:hidden"},
        h("summary", {className: "flex cursor-pointer items-center justify-between gap-4 font-semibold"}, str(props.question), h("span", {className: "text-primary transition group-open:rotate-45"}, "+")),
        h("p", {className: "mt-3 text-sm leading-6 opacity-70"}, str(props.answer)),
      ),

    steps: ({props, children}) =>
      band(
        props.tone,
        "",
        h(
          "div",
          {className: "space-y-10"},
          props.title ? h("h2", {className: "text-center text-2xl font-bold tracking-tight sm:text-3xl"}, str(props.title)) : null,
          h("div", {className: "grid gap-6 sm:grid-cols-3"}, React.Children.map(children, (c, i) => h("div", {className: "relative rounded-2xl border border-base-300/60 bg-base-100/70 backdrop-blur-xl p-6 text-base-content shadow-sm"}, h("div", {className: "mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-gradient-to-br from-primary to-accent text-sm font-bold text-primary-content"}, String(i + 1)), c))),
        ),
      ),
    step: ({props}) =>
      h(
        "div",
        {},
        props.title ? h("h3", {className: "text-lg font-bold"}, str(props.title)) : null,
        props.text ? h("p", {className: "mt-1.5 text-sm leading-6 opacity-60"}, str(props.text)) : null,
      ),

    cta: ({props}) =>
      h(
        "section",
        {className: `w-full px-6 py-20 text-center sm:py-24 ${toneClass(props.tone || "brand")}`},
        h(
          "div",
          {className: "mx-auto max-w-2xl space-y-5"},
          props.title ? h("h2", {className: "text-3xl font-bold tracking-tight sm:text-4xl"}, str(props.title)) : null,
          props.text ? h("p", {className: "text-base leading-7 opacity-85"}, str(props.text)) : null,
          props.button_label ? h("div", {className: "pt-2"}, h("a", {className: "inline-flex items-center justify-center rounded-xl bg-base-100 px-8 py-3.5 text-base font-bold text-primary shadow-lg transition hover:scale-105", href: str(props.button_href) || "#"}, str(props.button_label))) : null,
        ),
      ),

    footer: ({props}) =>
      h(
        "footer",
        {className: "w-full bg-neutral px-6 py-12 text-center text-sm text-neutral-content/70"},
        str(props.text) || "© 2026",
      ),
  }),
})

// LLM-authored pages carry made-up image `src`es (the model can't know real
// URLs), so a broken src is the COMMON case. Render a polished gradient
// placeholder (with the alt as a caption) on a missing OR failed-to-load src,
// instead of the browser's broken-image glyph.
function ImageNode({props}) {
  const [failed, setFailed] = React.useState(false)
  const alt = str(props.alt)
  const src = props.src ? String(props.src) : ""
  if (src && !failed) {
    return h("img", {className: "w-full rounded-2xl border border-base-300 object-cover shadow-sm", src, alt, loading: "lazy", onError: () => setFailed(true)})
  }
  return h(
    "div",
    {className: "flex aspect-[16/9] w-full flex-col items-center justify-center gap-2 rounded-2xl border border-base-300 bg-gradient-to-br from-primary/10 via-base-200 to-accent/10 text-base-content/40"},
    h("div", {className: "flex h-12 w-12 items-center justify-center rounded-xl bg-base-100/70 text-primary shadow-sm"}, h(Icon, {name: "globe", className: "h-6 w-6"})),
    alt ? h("span", {className: "px-4 text-center text-sm"}, alt) : null,
  )
}

function Unknown({element}) {
  return h("div", {className: "rounded-lg border border-dashed border-base-300 px-3 py-2 text-sm italic text-base-content/40"}, "Unsupported node: " + str(element && element.type))
}

export function JsonRenderPage({page}) {
  const spec = page && typeof page === "object" ? nestedToFlat(page) : null
  return h(JSONUIProvider, {registry}, h(Renderer, {spec, registry, fallback: Unknown}))
}
