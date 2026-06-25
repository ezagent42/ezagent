// Renderer-normalization regression test for the @json-render/shadcn customer
// page. Pure Node (no bundler) — exercises the exact `normalizeSpec` the live
// `catalog_jsonrender.mjs` runs before handing a spec to the shadcn renderer.
// Run via the Elixir wrapper `catalog_normalize_test.exs` (System.cmd node).

import assert from "node:assert/strict"
import {normalizeSpec, coerceRow, coerceCell} from "../js/catalog_normalize.mjs"

// --- Table rows: the `row.map is not a function` crash fix --------------------

// Object rows (a real LLM mistake) → 2D cell array.
{
  const out = normalizeSpec({
    type: "Table",
    props: {columns: ["name", "role"], rows: [{name: "Ada", role: "admin"}]},
  })
  assert.deepEqual(out.props.rows, [["Ada", "admin"]], "object row → cell array")
}

// Already-correct 2D string rows pass through unchanged.
{
  const out = normalizeSpec({type: "Table", props: {rows: [["a", "b"], ["c", "d"]]}})
  assert.deepEqual(out.props.rows, [["a", "b"], ["c", "d"]])
}

// Bare/nested-object cells are coerced, never throw. Primitives pass through as
// themselves (numbers stay numbers — React renders them); only objects/arrays are
// stringified (those are what make a shadcn Table cell throw).
assert.deepEqual(coerceRow("solo"), ["solo"])
assert.deepEqual(coerceRow({a: 1, b: 2}), [1, 2])
assert.equal(coerceCell({x: 1}), '{"x":1}')
assert.equal(coerceCell(7), 7)
assert.equal(coerceCell(null), "")

// --- Vertical Stack stretch: the squished-grid/cards fix ----------------------

// A vertical Stack holding a Grid gets align:stretch (so columns fill width).
{
  const out = normalizeSpec({
    type: "Stack",
    props: {direction: "vertical"},
    children: [{type: "Grid", props: {columns: 3}, children: []}],
  })
  assert.equal(out.props.align, "stretch", "vertical Stack w/ Grid → stretch")
}

// A leaf-only vertical Stack (heading/text/button) is NOT stretched — a lone
// button must keep its natural width, not fill the row.
{
  const out = normalizeSpec({
    type: "Stack",
    props: {direction: "vertical"},
    children: [
      {type: "Heading", props: {text: "Hi"}},
      {type: "Button", props: {label: "Go"}},
    ],
  })
  assert.equal(out.props.align, undefined, "leaf-only Stack stays items-start")
}

// An EXPLICIT align is never overridden.
{
  const out = normalizeSpec({
    type: "Stack",
    props: {direction: "vertical", align: "center"},
    children: [{type: "Card", props: {}, children: []}],
  })
  assert.equal(out.props.align, "center", "explicit align preserved")
}

// A HORIZONTAL Stack is left alone (stretch only applies to vertical).
{
  const out = normalizeSpec({
    type: "Stack",
    props: {direction: "horizontal"},
    children: [{type: "Grid", props: {}, children: []}],
  })
  assert.equal(out.props.align, undefined, "horizontal Stack untouched")
}

// --- Recursion + immutability -------------------------------------------------

// Normalization reaches nested nodes (a Grid inside a Stack inside the root).
{
  const root = {
    type: "Stack",
    props: {direction: "vertical", className: "page-root"},
    children: [
      {
        type: "Stack",
        props: {direction: "vertical"},
        children: [{type: "Grid", props: {}, children: []}],
      },
      {type: "Table", props: {rows: [{a: 1}]}},
    ],
  }
  const out = normalizeSpec(root)
  assert.equal(out.props.align, "stretch", "root w/ Stack child stretched")
  assert.equal(out.children[0].props.align, "stretch", "nested Stack stretched")
  assert.deepEqual(out.children[1].props.rows, [[1]], "nested Table coerced")
  // Original is not mutated.
  assert.equal(root.props.align, undefined, "input spec not mutated")
}

// Non-object input degrades, never throws.
assert.equal(normalizeSpec(null), null)
assert.equal(normalizeSpec("x"), "x")

console.log("catalog_normalize_test: all assertions passed")
