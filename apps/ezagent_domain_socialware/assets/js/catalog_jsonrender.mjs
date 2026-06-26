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
import {defineCatalog, nestedToFlat, markDevtoolsActive} from "@json-render/core"
import {shadcnComponentDefinitions} from "@json-render/shadcn/catalog"
import {shadcnComponents} from "@json-render/shadcn"
import {normalizeSpec} from "./catalog_normalize.mjs"

const h = React.createElement

const catalog = defineCatalog(schema, {components: shadcnComponentDefinitions, actions: {}})
const {registry} = defineRegistry(catalog, {components: shadcnComponents})

// @json-render's node tagging (`markDevtoolsActive`, public @json-render/core
// export): while active, every rendered node is wrapped in a
// `<span data-jr-key="el-N" style="display:contents">`, which lets point-to-edit
// map a clicked DOM element back to its SPEC node (the key indexes the flat spec
// below). NOT enabled globally — the wrapper span counts as a level for `>` /
// `:nth-child` CSS, which could shift a theme's zebra/adjacent rules. The
// selection UI turns it on ONLY while picking (re-exported here), then releases.
export {markDevtoolsActive}

// The flat spec of the CURRENT page: `{ "el-N": {type, props, children} }`. Kept
// here so the selection UI can resolve a clicked `data-jr-key` to its spec node
// (its real json-render type + props), instead of the raw DOM tag (h1/div/…).
let jrElements = {}

// Resolve a `data-jr-key` (e.g. "el-7") to its spec node `{type, props, children}`
// in the currently rendered page, or null. The key must come from the SAME
// normalized tree we render (markDevtoolsActive emits exactly this key).
export function lookupJrNode(key) {
  return (key && jrElements[key]) || null
}

function Unknown({element}) {
  return h(
    "div",
    {className: "rounded-lg border border-dashed px-3 py-2 text-sm italic opacity-50"},
    "Unsupported node: " + String(element && element.type),
  )
}

export function JsonRenderPage({page}) {
  const safe = page && typeof page === "object" ? normalizeSpec(page) : null
  const spec = safe ? nestedToFlat(safe) : null
  // Expose the flat node map for click-to-select reverse lookup. `nestedToFlat`
  // returns `{root, elements}`; `data-jr-key` values index `elements`.
  jrElements = spec && spec.elements ? spec.elements : {}
  return h(JSONUIProvider, {registry}, h(Renderer, {spec, registry, fallback: Unknown}))
}
