// Renders a json-render node tree (the SAME `@json-render/shadcn` spec the
// socialware preview page uses) inside a world chat bubble. A message whose body
// carries a `render` fragment (a table/card generated for a "show me the data"
// ask) renders here with the real engine, instead of plain text.
//
// Mirrors `apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs` +
// `catalog_normalize.mjs` — kept as a small self-contained copy because world is
// an independent bundle (its own React 19 + @json-render deps), so it cannot
// import the socialware SPA module at runtime.
import React from "react"
import {Renderer, JSONUIProvider, defineRegistry} from "@json-render/react"
import {schema} from "@json-render/react/schema"
import {defineCatalog, nestedToFlat} from "@json-render/core"
import {shadcnComponentDefinitions} from "@json-render/shadcn/catalog"
import {shadcnComponents} from "@json-render/shadcn"

const catalog = defineCatalog(schema, {components: shadcnComponentDefinitions, actions: {}})
const {registry} = defineRegistry(catalog, {components: shadcnComponents})

function Unknown({element}: {element?: {type?: string}}) {
  return (
    <div className="rounded-md border border-dashed px-2 py-1 text-xs italic opacity-50">
      Unsupported node: {String(element && element.type)}
    </div>
  )
}

// --- defensive normalization (same rules as the preview renderer) -------------

function coerceCell(c: unknown): unknown {
  if (c == null) return ""
  return typeof c === "object" ? JSON.stringify(c) : c
}

function coerceRow(row: unknown): unknown[] {
  if (Array.isArray(row)) return row.map(coerceCell)
  if (row && typeof row === "object") return Object.values(row as object).map(coerceCell)
  return [coerceCell(row)]
}

function isContainer(node: any): boolean {
  return (
    node &&
    (node.type === "Grid" || node.type === "Card" || node.type === "Table" || node.type === "Stack")
  )
}

function normalizeSpec(node: any): any {
  if (Array.isArray(node)) return node.map(normalizeSpec)
  if (!node || typeof node !== "object") return node

  let props = node.props

  if (node.type === "Table" && props && Array.isArray(props.rows)) {
    props = {...props, rows: props.rows.map(coerceRow)}
  }

  if (node.type === "Stack") {
    const p = props || {}
    const vertical = p.direction !== "horizontal"
    if (vertical && p.align == null) {
      const kids = Array.isArray(node.children) ? node.children : []
      if (kids.some(isContainer)) props = {...p, align: "stretch"}
    }
  }

  const children = Array.isArray(node.children) ? node.children.map(normalizeSpec) : node.children
  return {...node, props, children}
}

// A process-unique id per mounted card, so an injected theme scopes to THIS card.
let cardSeq = 0

export function JsonRenderBubble({
  spec,
  css,
  onSend,
}: {
  spec: unknown
  css?: string | null
  // Interaction model: any in-card action (a Button press, a Select change, an
  // Input submit, …) SENDS A CHAT MESSAGE as the user. `onSend(text)` posts it.
  onSend?: (text: string) => void
}) {
  const id = React.useMemo(() => `jr-card-${++cardSeq}`, [])

  // Every action a card can fire routes to "send a message as the user". The
  // model may name the action anything sensible (send/post/submit/filter/search/
  // refresh/ask) — they ALL map to the same send. The text comes from the action
  // `params` (a literal message, or a value read from an Input via {$state}).
  const handlers = React.useMemo(() => {
    const send = (params: any) => {
      const text = String(params?.message ?? params?.text ?? params?.query ?? params?.value ?? "").trim()
      if (text && onSend) onSend(text)
    }
    return {send, post: send, submit: send, filter: send, search: send, refresh: send, ask: send, query: send}
  }, [onSend])

  const safe = spec && typeof spec === "object" ? normalizeSpec(spec) : null
  const flat = safe ? nestedToFlat(safe) : null
  if (!flat) return null
  // The model writes the theme with un-prefixed selectors; wrap them in this
  // card's id (CSS nesting) so the user's style ask applies HERE only, never
  // leaking to other cards or the page.
  const scopedCss = css && css.trim() ? `#${id}{${css}}` : null
  return (
    <div
      id={id}
      className="page jr-bubble mt-2 max-w-full overflow-x-auto rounded-xl border border-border bg-card p-3 text-card-foreground shadow-sm [&_table]:text-sm"
    >
      {scopedCss ? <style dangerouslySetInnerHTML={{__html: scopedCss}} /> : null}
      <JSONUIProvider registry={registry} handlers={handlers}>
        <Renderer spec={flat as any} registry={registry} fallback={Unknown} />
      </JSONUIProvider>
    </div>
  )
}
