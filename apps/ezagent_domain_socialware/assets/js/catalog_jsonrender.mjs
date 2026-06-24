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

    image: ({props}) =>
      props.src
        ? h("img", {
            className: "w-full rounded-2xl border border-base-300 object-cover shadow-sm",
            src: String(props.src),
            alt: String(props.alt ?? ""),
            loading: "lazy",
          })
        : h(
            "div",
            {className: "rounded-2xl border border-dashed border-base-300 py-12 text-center text-sm italic text-base-content/40"},
            "Image unavailable",
          ),
  },
})

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
