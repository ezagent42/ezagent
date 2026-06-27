// The external-viewer-surface page renderer — now on the OFFICIAL Vercel
// `@json-render/shadcn` catalog (36 shadcn components: Stack/Grid/Card/Heading/
// Text/Button/Tabs/Accordion/Carousel/…). The AI generates a tree of these
// nodes; we render it with the real @json-render engine + shadcn registry.
//
// Convention (from @json-render/shadcn): leaf nodes carry their content in PROPS
// (Heading.text, Text.text, Button.label, Image.src); containers (Stack/Grid/
// Card/Tabs/…) take a `default` slot = the node's `children`. Styling comes from
// the shadcn theme (CSS vars in viewer.css) + each node's optional `className`.
import React from "react"
import {Renderer, JSONUIProvider, defineRegistry} from "@json-render/react"
import {schema} from "@json-render/react/schema"
import {defineCatalog, nestedToFlat} from "@json-render/core"
import {shadcnComponentDefinitions} from "@json-render/shadcn/catalog"
import {shadcnComponents} from "@json-render/shadcn"
import {normalizeSpec} from "./catalog_normalize.mjs"

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

export function JsonRenderPage({page}) {
  const safe = page && typeof page === "object" ? normalizeSpec(page) : null
  const spec = safe ? nestedToFlat(safe) : null
  return h(JSONUIProvider, {registry}, h(Renderer, {spec, registry, fallback: Unknown}))
}
