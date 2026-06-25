// The customer-surface page renderer — now on the OFFICIAL Vercel
// `@json-render/shadcn` catalog (36 shadcn components: Stack/Grid/Card/Heading/
// Text/Button/Tabs/Accordion/Carousel/…). The AI generates a tree of these
// nodes; we render it with the real @json-render engine + shadcn registry.
//
// Convention (from @json-render/shadcn): leaf nodes carry their content in PROPS
// (Heading.text, Text.text, Button.label, Image.src); containers (Stack/Grid/
// Card/Tabs/…) take a `default` slot = the node's `children`. Styling comes from
// the shadcn theme (CSS vars in customer.css) + each node's optional `className`.
import React from "react"
import {Renderer, JSONUIProvider, defineRegistry} from "@json-render/react"
import {schema} from "@json-render/react/schema"
import {defineCatalog, nestedToFlat} from "@json-render/core"
import {shadcnComponentDefinitions} from "@json-render/shadcn/catalog"
import {shadcnComponents} from "@json-render/shadcn"

const h = React.createElement

const catalog = defineCatalog(schema, {components: shadcnComponentDefinitions, actions: {}})
const {registry} = defineRegistry(catalog, {components: shadcnComponents})

function Unknown({element}) {
  return h(
    "div",
    {className: "rounded-lg border border-dashed px-3 py-2 text-sm italic opacity-50"},
    "Unsupported node: " + String(element && element.type),
  )
}

// Defensive coercion before rendering: the LLM occasionally emits a shape a
// shadcn component can't take (e.g. Table `rows` as objects instead of
// cell-arrays), which throws INSIDE the component (past the per-node error
// boundary's usefulness). Fix the known cases so a malformed node degrades
// gracefully instead of blanking out.
function coerceCell(c) {
  if (c == null) return ""
  return typeof c === "object" ? JSON.stringify(c) : c
}

function coerceRow(row) {
  if (Array.isArray(row)) return row.map(coerceCell)
  if (row && typeof row === "object") return Object.values(row).map(coerceCell)
  return [coerceCell(row)]
}

function normalizeSpec(node) {
  if (Array.isArray(node)) return node.map(normalizeSpec)
  if (!node || typeof node !== "object") return node
  let props = node.props
  // Table: rows MUST be an array of cell-arrays; coerce objects/strings.
  if (node.type === "Table" && props && Array.isArray(props.rows)) {
    props = {...props, rows: props.rows.map(coerceRow)}
  }
  // A vertical shadcn Stack defaults to `items-start`, so a Grid/Card/nested-Stack
  // child shrinks to its min-content width (CJK text then wraps one char per line,
  // the squished-columns bug). Default such a stack to `align:stretch` so its block
  // children fill the width — ONLY when it holds a container child, so a leaf-only
  // stack (heading/text/buttons) keeps items-start and buttons don't stretch full.
  if (node.type === "Stack") {
    const p = props || {}
    const vertical = p.direction !== "horizontal"

    if (vertical && p.align == null) {
      const kids = Array.isArray(node.children) ? node.children : []
      const hasContainer = kids.some(
        (c) => c && (c.type === "Grid" || c.type === "Card" || c.type === "Table" || c.type === "Stack"),
      )
      if (hasContainer) props = {...p, align: "stretch"}
    }
  }
  const children = Array.isArray(node.children) ? node.children.map(normalizeSpec) : node.children
  return {...node, props, children}
}

export function JsonRenderPage({page}) {
  const safe = page && typeof page === "object" ? normalizeSpec(page) : null
  const spec = safe ? nestedToFlat(safe) : null
  return h(JSONUIProvider, {registry}, h(Renderer, {spec, registry, fallback: Unknown}))
}
