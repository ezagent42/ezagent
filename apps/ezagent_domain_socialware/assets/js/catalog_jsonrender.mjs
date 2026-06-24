// The customer-surface page renderer, built on the REAL Vercel `@json-render`
// (not the homegrown `catalog_render.mjs`). Same catalog contract the server's
// `EzagentPluginHello.Spec` validates, but rendered through `@json-render/react`
// `Renderer` so the surface gets @json-render's state/visibility/action runtime
// (the path to declarable interactivity) — and styled with a polished,
// "official-site"-grade Tailwind/daisyUI design pass.
//
// Written with `React.createElement` (no JSX) so it bundles under the customer
// SPA's esbuild without a JSX-runtime pragma. Components receive `{props,
// children}` from @json-render (children are already-rendered React nodes).
import React from "react"
import {Renderer, JSONUIProvider, defineRegistry} from "@json-render/react"
import {schema} from "@json-render/react/schema"
import {defineCatalog, nestedToFlat} from "@json-render/core"
import {z} from "zod"

const h = React.createElement
const opt = z.string().nullable().optional()
const optNum = z.union([z.number(), z.string()]).nullable().optional()

// ── Catalog (schema) — MUST mirror EzagentPluginHello.Spec.catalog ───────────
const catalog = defineCatalog(schema, {
  components: {
    page: {props: z.object({title: opt}), description: "Page root: optional title + a vertical stack of children."},
    section: {props: z.object({layout: opt}), description: "A grouping section; layout 'stack' (default) or 'grid'."},
    card: {props: z.object({title: opt}), description: "A titled card wrapping its children."},
    heading: {props: z.object({text: opt, level: optNum}), description: "A heading; level 1–6 (default 2)."},
    text: {props: z.object({text: opt}), description: "A paragraph of text."},
    button: {props: z.object({label: opt, href: opt}), description: "A link when href is set, else a plain button."},
    image: {props: z.object({src: opt, alt: opt}), description: "A responsive image."},
    hero: {props: z.object({title: opt, subtitle: opt, cta_label: opt, cta_href: opt}), description: "Big centered hero banner: title + subtitle + a call-to-action button. Use ONE at the top of the page."},
    features: {props: z.object({title: opt}), description: "A features section with an optional title; children are `feature` nodes laid out in a responsive grid."},
    feature: {props: z.object({title: opt, text: opt}), description: "One feature card (title + short description). Use inside `features`."},
    cta: {props: z.object({title: opt, text: opt, button_label: opt, button_href: opt}), description: "A prominent call-to-action banner (colored): title + text + button. Use near the bottom."},
    stats: {props: z.object({}), description: "A row of metrics; children are `stat` nodes."},
    stat: {props: z.object({value: opt, label: opt}), description: "One metric: a big value + a label. Use inside `stats`."},
  },
  actions: {},
})

const clampLevel = (v) => {
  const n = Number(v)
  return Number.isFinite(n) ? Math.min(6, Math.max(1, Math.trunc(n))) : 2
}

// ── Registry (implementations) — the "official-site" design pass ─────────────
const HEADING_CLASS = {
  1: "text-4xl sm:text-5xl font-bold tracking-tight text-base-content",
  2: "text-2xl sm:text-3xl font-bold tracking-tight text-base-content",
  3: "text-xl font-semibold text-base-content",
  4: "text-lg font-semibold text-base-content",
  5: "text-base font-semibold text-base-content",
  6: "text-sm font-semibold uppercase tracking-wide text-base-content/60",
}

const {registry} = defineRegistry(catalog, {
  components: {
    page: ({props, children}) =>
      h(
        "div",
        {className: "mx-auto w-full max-w-3xl px-1 py-2 space-y-10 sm:space-y-14"},
        props.title
          ? h("h1", {className: "text-4xl sm:text-5xl font-bold tracking-tight text-base-content"}, String(props.title))
          : null,
        children,
      ),

    section: ({props, children}) =>
      props.layout === "grid"
        ? h("section", {className: "grid gap-5 sm:grid-cols-2 lg:grid-cols-3"}, children)
        : h("section", {className: "space-y-6"}, children),

    card: ({props, children}) =>
      h(
        "div",
        {className: "rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm transition hover:shadow-md space-y-3"},
        props.title ? h("h3", {className: "text-lg font-semibold text-base-content"}, String(props.title)) : null,
        children,
      ),

    heading: ({props}) => {
      const lvl = clampLevel(props.level)
      return h("h" + lvl, {className: HEADING_CLASS[lvl]}, String(props.text ?? ""))
    },

    text: ({props}) =>
      h("p", {className: "max-w-prose text-base leading-7 text-base-content/70"}, String(props.text ?? "")),

    button: ({props}) => {
      const label = String(props.label ?? "")
      const cls =
        "inline-flex items-center justify-center rounded-lg bg-primary px-5 py-2.5 text-sm font-semibold text-primary-content shadow-sm transition hover:opacity-90"
      return props.href
        ? h("a", {className: cls, href: String(props.href)}, label)
        : h("button", {className: cls, type: "button"}, label)
    },

    image: ImageNode,

    // ── Block-level "official-site" components ──────────────────────────────
    hero: ({props}) =>
      h(
        "section",
        {className: "overflow-hidden rounded-3xl bg-gradient-to-br from-primary via-primary to-accent px-6 py-20 text-center text-primary-content shadow-xl shadow-primary/30 sm:py-28"},
        h(
          "div",
          {className: "mx-auto max-w-2xl space-y-6"},
          props.title ? h("h1", {className: "text-4xl font-extrabold tracking-tight text-primary-content drop-shadow-sm sm:text-6xl"}, String(props.title)) : null,
          props.subtitle ? h("p", {className: "text-lg leading-8 text-primary-content/85 sm:text-xl"}, String(props.subtitle)) : null,
          props.cta_label
            ? h(
                "div",
                {className: "pt-2"},
                h(
                  "a",
                  {
                    className: "inline-flex items-center justify-center rounded-xl bg-base-100 px-8 py-3.5 text-base font-bold text-primary shadow-lg transition hover:scale-105 hover:shadow-xl",
                    href: String(props.cta_href || "#"),
                  },
                  String(props.cta_label),
                ),
              )
            : null,
        ),
      ),

    features: ({props, children}) =>
      h(
        "section",
        {className: "space-y-8"},
        props.title ? h("h2", {className: "text-center text-2xl font-bold tracking-tight text-base-content sm:text-3xl"}, String(props.title)) : null,
        h("div", {className: "grid gap-6 sm:grid-cols-2 lg:grid-cols-3"}, children),
      ),

    feature: ({props}) =>
      h(
        "div",
        {className: "group rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm transition hover:-translate-y-1 hover:border-primary/40 hover:shadow-lg hover:shadow-primary/10"},
        h(
          "div",
          {className: "mb-4 inline-flex h-12 w-12 items-center justify-center rounded-xl bg-gradient-to-br from-primary to-accent text-xl font-bold text-primary-content shadow-md shadow-primary/30"},
          "✦",
        ),
        props.title ? h("h3", {className: "text-lg font-bold text-base-content"}, String(props.title)) : null,
        props.text ? h("p", {className: "mt-2 text-sm leading-6 text-base-content/60"}, String(props.text)) : null,
      ),

    cta: ({props}) =>
      h(
        "section",
        {className: "rounded-3xl bg-gradient-to-r from-primary to-accent px-6 py-14 text-center text-primary-content shadow-xl shadow-primary/30 sm:py-16"},
        h(
          "div",
          {className: "mx-auto max-w-xl space-y-4"},
          props.title ? h("h2", {className: "text-2xl font-bold tracking-tight sm:text-3xl"}, String(props.title)) : null,
          props.text ? h("p", {className: "text-base leading-7 text-primary-content/80"}, String(props.text)) : null,
          props.button_label
            ? h(
                "div",
                {className: "pt-2"},
                h(
                  "a",
                  {
                    className: "inline-flex items-center justify-center rounded-xl bg-base-100 px-7 py-3 text-base font-semibold text-base-content shadow-lg transition hover:opacity-90",
                    href: String(props.button_href || "#"),
                  },
                  String(props.button_label),
                ),
              )
            : null,
        ),
      ),

    stats: ({children}) =>
      h(
        "section",
        {className: "grid grid-cols-2 gap-6 rounded-2xl border border-primary/20 bg-gradient-to-r from-primary/5 to-accent/5 px-6 py-10 sm:grid-cols-4"},
        children,
      ),

    stat: ({props}) =>
      h(
        "div",
        {className: "text-center"},
        h("div", {className: "bg-gradient-to-br from-primary to-accent bg-clip-text text-4xl font-extrabold tracking-tight text-transparent sm:text-5xl"}, String(props.value ?? "")),
        h("div", {className: "mt-1.5 text-sm font-medium text-base-content/60"}, String(props.label ?? "")),
      ),
  },
})

// LLM-authored pages carry made-up image `src`es (the model can't know real
// URLs), so a broken src is the COMMON case. Render a polished gradient
// placeholder (with the alt as a caption) on a missing OR failed-to-load src,
// instead of the browser's broken-image glyph.
function ImageNode({props}) {
  const [failed, setFailed] = React.useState(false)
  const alt = String(props.alt ?? "")
  const src = props.src ? String(props.src) : ""

  if (src && !failed) {
    return h("img", {
      className: "w-full rounded-2xl border border-base-300 object-cover shadow-sm",
      src,
      alt,
      loading: "lazy",
      onError: () => setFailed(true),
    })
  }

  return h(
    "div",
    {className: "flex aspect-[16/9] w-full flex-col items-center justify-center gap-2 rounded-2xl border border-base-300 bg-gradient-to-br from-primary/10 via-base-200 to-accent/10 text-base-content/40"},
    h("div", {className: "flex h-12 w-12 items-center justify-center rounded-xl bg-base-100/70 text-2xl shadow-sm"}, "🖼"),
    alt ? h("span", {className: "px-4 text-center text-sm"}, alt) : null,
  )
}

function Unknown({element}) {
  return h(
    "div",
    {className: "rounded-lg border border-dashed border-base-300 px-3 py-2 text-sm italic text-base-content/40"},
    "Unsupported node: " + String(element?.type),
  )
}

// The customer page, rendered through @json-render. `page` is the nested
// {type, props, children} Surface tree; we convert to @json-render's flat spec.
export function JsonRenderPage({page}) {
  const spec = page && typeof page === "object" ? nestedToFlat(page) : null
  return h(JSONUIProvider, {registry}, h(Renderer, {spec, registry, fallback: Unknown}))
}
