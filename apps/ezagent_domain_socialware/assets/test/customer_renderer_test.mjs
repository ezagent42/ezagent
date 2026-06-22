import assert from "node:assert/strict"
import {createBaseRegistry, renderJsonNode, renderTree} from "../js/catalog_render.mjs"

let sandpackRenderCount = 0

const React = {
  createElement(type, props = {}, ...children) {
    return {type, props: props || {}, children: children.flat()}
  },
}

function Sandpack(props) {
  sandpackRenderCount += 1
  return React.createElement("iframe", {
    "data-sandpack": "true",
    sandbox: "allow-scripts",
    ...props,
  })
}

const registry = createBaseRegistry(React, Sandpack)

const tree = {
  type: "container",
  props: {layout: "stack"},
  children: [
    {type: "text", props: {text: "hello"}},
    {
      type: "table",
      props: {
        columns: ["name", "score"],
        rows: [{name: "Ada", score: 10}],
      },
    },
  ],
}

const rendered = renderJsonNode(React, tree, registry)
const renderedContainer = rendered.type(rendered.props)
assert.equal(renderedContainer.type, "section")
// sw-* contract classes are preserved (styling Tailwind/daisyUI classes are
// added ALONGSIDE — the agent-browser E2E + downstream tooling key off sw-*).
assert.match(renderedContainer.props.className, /\bsw-container\b/)
assert.match(renderedContainer.props.className, /\bsw-container-stack\b/)

// The styled container wraps its rendered children in a daisyUI `card-body`
// div for padding/spacing; the per-child keys (and the #36 regression) live on
// that wrapper's children.
const cardBody = renderedContainer.children[0]
assert.equal(cardBody.type, "div")
const containerChildren = cardBody.children

const textNode = containerChildren[0].type(containerChildren[0].props)
assert.equal(textNode.type, "p")
assert.match(textNode.props.className, /\bsw-text\b/)
assert.equal(textNode.children[0], "hello")

const tableNode = containerChildren[1].type(containerChildren[1].props)
assert.equal(tableNode.type, "table")
assert.match(tableNode.props.className, /\bsw-table\b/)
assert.match(tableNode.props.className, /\btable-zebra\b/)

// #36 regression: keyless container children get a STABLE, UNIQUE key from their
// index — incl. index 0. Pre-fix `child.key || index` / `node.key || undefined`
// coerced the falsy index 0 to `undefined`, dropping the first child's key and
// triggering React's "unique key" warning. The `??` fix keeps 0.
assert.equal(containerChildren[0].props.key, 0)
assert.equal(containerChildren[1].props.key, 1)
const childKeys = containerChildren.map((c) => c.props.key)
assert.equal(new Set(childKeys).size, childKeys.length, "container child keys must be unique")
assert.ok(
  childKeys.every((k) => k !== undefined),
  "no container child key may be undefined"
)

const unknown = renderJsonNode(React, {type: "chart", props: {title: "x"}}, registry)
const unknownNode = unknown.type(unknown.props)
assert.equal(unknownNode.type, "div")
assert.match(unknownNode.props.className, /\bsw-unknown-node\b/)
assert.equal(unknownNode.props["data-node-type"], "chart")
assert.match(unknownNode.children[0], /Unsupported node type/)

sandpackRenderCount = 0
renderTree(React, tree, registry)
assert.equal(sandpackRenderCount, 0)

const code = renderJsonNode(
  React,
  {type: "code", props: {language: "jsx", source: "export default function App(){return <h1/>}"}},
  registry
)
const codeNode = code.type(code.props)
assert.equal(codeNode.type, Sandpack)
const sandpackFrame = codeNode.type(codeNode.props)
assert.equal(sandpackFrame.type, "iframe")
assert.equal(sandpackFrame.props.sandbox, "allow-scripts")
assert.match(sandpackFrame.props.files["/App.js"], /export default function App/)
assert.equal(sandpackRenderCount, 1)
