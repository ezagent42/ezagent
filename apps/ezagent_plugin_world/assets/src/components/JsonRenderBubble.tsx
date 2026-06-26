// Renders a json-render node tree (the SAME `@json-render/shadcn` spec the
// socialware preview page uses) inside a world chat bubble. A message whose body
// carries a `render` fragment (a table/card generated for a "show me the data"
// ask) renders here with the real engine, instead of plain text.
//
// Mirrors `apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs` +
// `catalog_normalize.mjs` — kept as a small self-contained copy because world is
// an independent bundle (its own React 19 + @json-render deps), so it cannot
// import the socialware SPA module at runtime.
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

export function JsonRenderBubble({spec}: {spec: unknown}) {
  const safe = spec && typeof spec === "object" ? normalizeSpec(spec) : null
  const flat = safe ? nestedToFlat(safe) : null
  if (!flat) return null
  return (
    <div className="page jr-bubble mt-1.5 overflow-x-auto rounded-lg border border-border bg-background p-2">
      <JSONUIProvider registry={registry}>
        <Renderer spec={flat as any} registry={registry} fallback={Unknown} />
      </JSONUIProvider>
    </div>
  )
}
