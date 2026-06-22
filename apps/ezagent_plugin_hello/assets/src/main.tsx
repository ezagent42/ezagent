import {createRoot, type Root} from "react-dom/client"
import {Renderer, type Spec} from "@json-render/react"
import {nestedToFlat} from "@json-render/core"
import {registry} from "./registry"

// The island entry. The `HelloRenderer` phx-hook dynamically imports this module
// and calls `mountHello(el, {spec})` with the session's approved Surface tree
// (the nested `{type, props, children}` map). We convert it to @json-render's
// flat spec (`nestedToFlat`) and render it with the shared catalog registry, so
// the OPERATOR sees the page through the SAME @json-render renderer as the
// customer — no more degraded "Unsupported node" HEEx fallback.

const roots = new WeakMap<HTMLElement, Root>()

function Unknown({element}: {element: {type?: string}}) {
  return (
    <div style={{border: "1px dashed #d1d5db", borderRadius: 8, padding: "8px 12px", fontSize: 13, fontStyle: "italic", color: "#9ca3af"}}>
      Unsupported node: {String(element?.type)}
    </div>
  )
}

export function mountHello(el: HTMLElement, opts: {spec?: Record<string, unknown> | null} = {}) {
  roots.get(el)?.unmount()
  const root = createRoot(el)
  roots.set(el, root)

  const tree = opts.spec
  const spec: Spec | null = tree && typeof tree === "object" ? (nestedToFlat(tree) as Spec) : null
  root.render(<Renderer spec={spec} registry={registry} fallback={Unknown} />)

  return () => {
    root.unmount()
    roots.delete(el)
  }
}
