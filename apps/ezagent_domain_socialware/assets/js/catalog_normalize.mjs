// Pure, dependency-free spec normalization run before the @json-render/shadcn
// renderer sees an LLM-authored page. Kept separate from `catalog_jsonrender.mjs`
// (which imports React + the shadcn registry) so it can be unit-tested in plain
// Node without a bundler — see `assets/test/catalog_normalize_test.mjs`.

// A Table cell must be a string-ish primitive; an object/array cell would make
// the shadcn Table throw, so stringify it.
export function coerceCell(c) {
  if (c == null) return ""
  return typeof c === "object" ? JSON.stringify(c) : c
}

// shadcn Table wants `rows` as a 2D array (each row = a cell array). The model
// sometimes emits row objects or a bare value; coerce both to a cell array so
// `row.map(...)` inside the component never throws.
export function coerceRow(row) {
  if (Array.isArray(row)) return row.map(coerceCell)
  if (row && typeof row === "object") return Object.values(row).map(coerceCell)
  return [coerceCell(row)]
}

// Whether a node is a layout container whose width should fill its parent.
function isContainer(node) {
  return (
    node &&
    (node.type === "Grid" || node.type === "Card" || node.type === "Table" || node.type === "Stack")
  )
}

// Defensive coercion before rendering:
//  - Table `rows` → a 2D cell array (the `row.map is not a function` crash fix).
//  - A VERTICAL Stack defaults to `items-start` in shadcn, so a Grid/Card/nested
//    Stack child shrinks to min-content width (CJK text then wraps one char per
//    line — the squished-columns bug). Default such a stack to `align:stretch` so
//    block children fill the width — ONLY when it actually holds a container
//    child, so a leaf-only stack (heading/text/buttons) keeps items-start and a
//    lone button is not stretched full-width. An explicit `align` is never
//    overridden.
export function normalizeSpec(node) {
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
